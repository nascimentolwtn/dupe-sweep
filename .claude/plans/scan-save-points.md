# Scan Save Points (resumable scanning)

## Problem

Scanning ~7,000 photos is slow (see `.claude/plans/fix-scan-performance.md` if it
exists by the time this is implemented — that's a separate effort to make the
scan loop itself faster/concurrent; don't assume it has landed, and don't
assume it hasn't). Regardless of scan speed, today **any interruption loses
all progress**: `PhotoScannerService.scanAllPhotos` (`lib/services/photo_scanner_service.dart`)
builds its whole `List<PhotoItem>` result in memory and only returns it at
the very end of the loop (line 81). If the app is backgrounded and killed by
Android, the user hits system back, or anything crashes mid-scan, the next
scan starts over from photo zero — including re-computing every dHash.

This plan adds a durable, incremental save point so a scan can be paused
(deliberately or by force) and resumed later without re-processing photos
already handled.

## Reference pattern (already validated)

`E:\dev\dupe-sweep\python-mvp1\find_duplicate_photos.py` (lines 189–238) does
exactly this, in Python, against a JSON file:

1. On start, load `hash_cache.json` into `cache: dict[str, {ts, hash, size}]`
   if it exists (lines 189–195).
2. Compute `missing = [p for p in paths if str(p) not in cache]` — only
   unprocessed paths are worked on (line 197).
3. As each item finishes, write its result into `cache[key]` in memory, and
   **every 100 processed items, dump the entire `cache` dict back to
   `hash_cache.json`** (lines 218–223) — not just at the end, so a mid-run
   kill loses at most ~100 items of progress.
4. On restart, the same code path automatically re-loads the cache and
   resumes — there's no separate "resume" code path, resuming is just
   "run again."
5. A final unconditional write happens after the loop too, in case the last
   partial batch (< 100 items) never hit the modulo checkpoint (line 229).

This plan ports that exact shape into Dart: key by `AssetEntity.id`, persist
`{dhash, createDateTimeMillis, fileSize}` per key, checkpoint periodically
during the scan, and treat "resume" as the default path with "start over" as
an explicit opt-out.

## Storage choice: plain JSON file via `path_provider`, not a database plugin

Data shape is a flat map: `assetId (String) -> {dhash: String,
createDateTimeMillis: int, fileSize: int}`, ~7,000 entries, each entry maybe
150–250 bytes serialized → a full cache file is roughly 1–2 MB at worst.
Three options were considered:

- **`shared_preferences`** — Would mean JSON-encoding the entire map into one
  string value and calling `setString`. Functionally works, but
  `shared_preferences` is backed by an XML file on Android that's meant for
  small key/value settings, not a growing multi-hundred-KB blob rewritten
  every few seconds during a scan; it also gets loaded in full at plugin
  init even when unused. No real advantage over a plain file here.
- **`sqflite` (or Hive)** — A real embedded database would let single rows
  be upserted without rewriting the whole dataset, which is attractive at
  larger scale. But it's a native-code plugin (this project's git history —
  see "Fix Android build and import structure" — shows Android build
  fragility has already been a pain point), it needs schema/adapter
  boilerplate for a shape this simple, and at ~7,000 rows the "rewrite the
  whole file" cost of the JSON approach is trivial (low milliseconds).
  Worth revisiting only if the library size grows an order of magnitude, or
  if `fix-scan-performance.md`'s concurrency changes make the checkpoint
  cadence (see below) too write-heavy for whole-file rewrites.
- **Plain JSON file in app-local storage via `path_provider`** (recommended)
  — Directly mirrors the already-validated Python reference. `path_provider`
  is a first-party Flutter-team plugin (low build risk, same tier as
  `permission_handler`/`photo_manager` already in use), needs no schema, and
  gives us one file we fully control — trivial to delete for "start over",
  trivial to inspect while debugging. Read whole file into a `Map` at scan
  start; write whole file back to disk on each checkpoint using
  `jsonEncode`/`jsonDecode` from `dart:convert`.

**Recommendation: add `path_provider` and use a raw JSON file.** This is the
only new dependency this feature needs.

### Where the file lives, and the "no cloud" constraint

Use `getApplicationSupportDirectory()` (from `path_provider`) — Android
app-private storage, not user-visible, not the Pictures/Downloads tree. This
satisfies "no cloud sync" in the sense that *DupeSweep* never transmits
anything. However: `E:\dev\dupe-sweep\android\app\src\main\AndroidManifest.xml`
currently sets no `android:allowBackup` value, which **defaults to `true`**,
and there's no `android/app/src/main/res/xml/` backup-rules file present.
That means Android's OS-level Auto Backup (and Android 12+ device-to-device
transfer) could, by default, sweep this cache file — which contains photo
IDs, timestamps, and file sizes, i.e. metadata about the user's photo
library — into the user's Google account backup. That's in tension with
CLAUDE.md's "Privacy: Never log or transmit photo data, paths, or metadata
beyond the device."

This plan includes closing that gap:
- Add `android:allowBackup="false"` to the `<application>` tag in
  `AndroidManifest.xml` (simplest, fully closes it — also stops any other
  app data, e.g. future settings, from being cloud-backed-up), **or**, if
  `allowBackup="false"` is judged too broad, add
  `android:fullBackupContent="@xml/backup_rules"` /
  `android:dataExtractionRules="@xml/data_extraction_rules"` pointing at a
  new `android/app/src/main/res/xml/backup_rules.xml` that excludes the
  scan cache file's path specifically.
- Decide which of the two during implementation (flag it as an open
  question for the implementer if no other app state exists yet that
  *should* be backed up — in that case `allowBackup="false"` is simplest and
  strictly more private).

## Persistence schema

File: `scan_cache.json` in `getApplicationSupportDirectory()`.

```json
{
  "version": 1,
  "totalKnownAssets": 7102,
  "updatedAtMillis": 1755000000000,
  "entries": {
    "<AssetEntity.id>": {
      "dhash": "a1b2c3d4e5f60718",
      "createDateTimeMillis": 1734000000000,
      "fileSize": 4213556
    }
  }
}
```

Notes:
- `entries` key is `AssetEntity.id` (stable per `photo_manager` asset,
  matches `PhotoItem.id`).
- Stored fields are exactly enough to reconstruct a `PhotoItem` without
  re-hitting `photo_manager`/re-decoding the thumbnail for that asset:
  `dhash`, `createDateTime` (as epoch millis — `PhotoItem.createDateTime` is
  a `DateTime`), `fileSize`. `path` (`PhotoItem.path`) is intentionally
  **not** cached — it's cheap to re-fetch from `AssetEntity.relativePath`
  and can legitimately change between sessions (file moved/renamed), so
  caching it risks staleness; re-read it live when reconstructing.
- `dhash` may be `null`/absent if hashing failed for that asset (mirror the
  existing `PhotoItem.dhash` nullability and the current try/catch around
  `SimilarityService.computeDHash` in `photo_scanner_service.dart` lines
  55–65) — a failed-hash asset should still count as "processed" so it's
  not retried forever, matching the Python reference's `hash: None` case.
- `version` is a schema version int, bumped only if the entry shape changes
  later; unknown/mismatched version on load → treat as "no usable cache"
  (see invalidation below) rather than attempting a lossy migration.
- `totalKnownAssets` and `updatedAtMillis` are for UI purposes (resume
  banner text, e.g. "Resume scan (4,231/7,102 done)") and light staleness
  reasoning — not correctness-critical, since real correctness comes from
  diffing entries against the current live asset list (below).

## Invalidation / staleness handling

The library can change between sessions (photos added or deleted). Resume
must not crash or produce wrong results in either case:

- **Photos added since last save point**: handled for free. On resume, the
  scanner fetches the live asset list from `photo_manager` (as it already
  does), and computes `missing = liveAssets.where((a) =>
  !cache.entries.containsKey(a.id))` — new assets are simply "not yet in the
  cache" and get processed normally, exactly like the Python
  `missing = [p for p in paths if str(p) not in cache]` line.
- **Photos deleted since last save point**: their cache entries become
  orphans (ids that exist in `cache.entries` but not in the live asset
  list). Do not attempt to delete/prune them defensively on every load
  (wasted work); instead, when reconstructing `PhotoItem`s for the
  already-cached IDs, only reconstruct for `liveAssets` — i.e. always drive
  reconstruction off the live `AssetEntity` list filtered by "id is in
  cache," never off the cache's key set directly. An orphaned cache entry
  then simply never gets read back out and ages out naturally the next time
  the whole cache is rewritten (since rewriting means starting a fresh
  `entries` map keyed by the reconstruction pass). No crash risk, no need
  for an explicit prune step.
- **No forced expiry by age.** A save point never goes stale just by time
  passing — only "start over" (user-initiated) discards it. Don't add a TTL.
- **Corrupt/unreadable file** (partial write from a hard kill mid-`writeAsString`,
  garbage bytes, wrong `version`): treat exactly like "no cache exists" —
  log and start a fresh scan. Never let a bad cache file crash the scan
  screen. This is also why the write path should write-to-temp-then-rename
  (see checkpoint step below) rather than write the target file in place.

## UI/UX flow

`ScanProgressScreen` (`lib/screens/scan_progress_screen.dart`) currently has
exactly two states driven by `provider.isScanning`: an idle "Ready to Scan"
view with a single "Start Scan" button (lines 194–232), and an in-progress
view (lines 170–193). Add a third idle sub-state:

- On `initState` (or just before showing the idle view), asynchronously
  check whether a usable save point exists (`ScanCacheService.peekSummary()`
  — cheap, reads just enough to report counts without reconstructing every
  `PhotoItem`). While that check is pending, keep showing the existing idle
  view (or a tiny inline loading state) — don't block first paint on disk
  I/O.
- If a save point exists with `processedCount < totalKnownAssets` (i.e. a
  genuinely partial scan, not a stale-but-complete one — see below):
  replace the single "Start Scan" button with two actions:
  - **Primary**: "Resume scan (4,231/7,102 done)" — calls the scan entry
    point with `resume: true`.
  - **Secondary** (visually de-emphasized, e.g. `TextButton`): "Start over"
    — calls `ScanCacheService.clear()` then starts a fresh scan
    (`resume: false`). Consider a confirmation dialog since this discards
    real (if partial) work — the app has no other precedent for a
    destructive confirm dialog yet, so a simple `AlertDialog` is fine, no
    need to over-engineer.
- If no save point exists, behavior is unchanged (single "Start Scan"
  button).
- If a save point exists but is already complete (`processedCount ==
  totalKnownAssets` and matches the current live asset count) — this
  shouldn't normally be reachable, since a completed scan should hand off
  to `DuplicateReviewScreen` and clear the in-progress cache (see step 4
  below), but treat it defensively the same as "no save point" (fall
  through to normal "Start Scan") rather than showing a confusing "resume"
  option with nothing left to resume.
- During an active scan (`provider.isScanning == true`), the progress view
  is unchanged visually; the periodic checkpoint writes (below) happen
  silently in the background. No new UI needed here beyond what's already
  driving `scanStatus`/`scanProgress`.

## Checkpoint cadence — must not assume a sequential for-loop

`fix-scan-performance.md` may change `PhotoScannerService.scanAllPhotos`'s
current strictly-sequential `for (int i = 0; i < allAssets.length; i++)`
loop (lines 50–76) into something batched or concurrent (e.g. `Future.wait`
over chunks, an isolate pool, etc). The checkpoint mechanism must not assume
"item N finishes strictly after item N-1." Design it as:

- `ScanCacheService` exposes a method like `recordProcessed(String assetId,
  {String? dhash, required int createDateTimeMillis, required int
  fileSize})` that upserts one entry into an **in-memory** map the service
  owns (not disk I/O — cheap, safe to call from any completion callback
  regardless of ordering or concurrency).
- Separately, `ScanCacheService` exposes `Future<void> maybeCheckpoint()` (or
  is driven by an internal timer) that flushes the in-memory map to disk
  when either **N new entries have accumulated since the last flush** (e.g.
  every 100, matching the Python reference's cadence) **or** a wall-clock
  interval has elapsed (e.g. every 5 seconds) — whichever comes first. The
  time-based trigger matters once the loop is concurrent/batched, since
  "every 100 items" could otherwise mean "every 0.3 seconds" (too much I/O)
  or "every 30 seconds" (too much lost progress) depending on batch/worker
  count — a wall-clock ceiling bounds worst-case lost progress regardless of
  throughput.
- Call `recordProcessed` from wherever an individual photo finishes being
  hashed/scored, and call `maybeCheckpoint()` from the same place (it's a
  cheap no-op check when neither threshold is hit) — this makes the call
  site a single line droppable into a sequential loop body, a
  `Future.wait(batch.map(...))` completion callback, or an isolate result
  stream listener, without the caller needing to know or coordinate
  ordering.
- The actual disk write inside `maybeCheckpoint()` should write to a temp
  file (`scan_cache.json.tmp`) and rename over the real file, so a kill
  mid-write can never leave a half-written `scan_cache.json` behind (this is
  also the standard fix for the corrupt-file case in "Invalidation" above).
- On scan completion (all assets processed, `finishScan` about to be called
  in `ScanProgressScreen`), do one final unconditional
  `ScanCacheService.flush()` — mirrors the Python reference's unconditional
  write after the loop (line 229) — then, once `PhotoGroup`s are
  successfully built and handed to the provider, call
  `ScanCacheService.clear()` to delete the save-point file. A *finished*
  scan shouldn't leave behind a "resume" prompt next launch; the whole
  point of the cache is bridging an *interrupted* scan, not caching results
  across normal completed runs (that's a separate, not-yet-planned
  "re-scan and merge" feature already noted in CLAUDE.md's roadmap).

## Implementation steps

1. **`pubspec.yaml`** (`E:\dev\dupe-sweep\pubspec.yaml`): add
   `path_provider: ^2.1.0` (check current latest compatible with the SDK
   constraint already in the file, `>=3.0.0 <4.0.0`, and with
   `photo_manager: ^3.12.0`/`permission_handler: ^13.0.1` already present)
   under `dependencies:`. Run `flutter pub get` after.

2. **New file `lib/services/scan_cache_service.dart`**:
   - A small data class, e.g. `CachedPhotoData { String? dhash; int
     createDateTimeMillis; int fileSize; }` with `toJson`/`fromJson`.
   - `ScanCacheService` class (instance, not static-only, so it can hold
     in-memory checkpoint state across calls during one scan):
     - `Future<void> load()` — reads `scan_cache.json` from
       `getApplicationSupportDirectory()` if present, parses it, populates
       an in-memory `Map<String, CachedPhotoData>`. Any parse failure or
       `version` mismatch → treat as empty cache (log, don't throw).
     - `Map<String, CachedPhotoData> get cachedEntries` — read accessor
       for already-processed data (used by the scanner to skip work and by
       resume-summary UI).
     - `void recordProcessed(String assetId, CachedPhotoData data)` —
       in-memory upsert, as described above.
     - `Future<void> maybeCheckpoint({int everyN = 100, Duration
       everyDuration = const Duration(seconds: 5)})` — flush-to-disk if
       either threshold crossed since last flush.
     - `Future<void> flush()` — unconditional write-temp-then-rename.
     - `Future<void> clear()` — delete the cache file (and reset in-memory
       state); used by "Start over" and by successful scan completion.
     - `Future<ScanCacheSummary?> peekSummary()` — cheap read for the UI
       resume prompt; returns `null` if no usable cache, otherwise
       `{processedCount, totalKnownAssets, updatedAtMillis}`. Can reuse
       `load()` internally (loading ~7,000 small JSON entries is fast; no
       need for a separate lightweight parse path unless profiling later
       says otherwise).

3. **`lib/services/photo_scanner_service.dart`** changes:
   - Add an optional `ScanCacheService? cache` parameter to
     `scanAllPhotos(...)` (default `null` → behaves exactly as today, no
     caching, useful for existing tests / simple callers).
   - Before the main loop: if `cache != null`, call `cache.load()` (if not
     already loaded by the caller — decide whether `ScanProgressScreen` or
     this method owns the `load()` call; recommend the screen owns
     construction+load so it can also read `peekSummary()` before deciding
     resume-vs-fresh, then passes the already-loaded instance in).
   - Change the loop to skip assets already present in
     `cache.cachedEntries`: for those, reconstruct a `PhotoItem` directly
     from the cached `dhash`/`createDateTimeMillis`/`fileSize` plus a fresh
     `asset.relativePath` for `path` (cheap, no thumbnail decode needed) —
     do **not** call `thumbnailDataWithSize`/`computeDHash` again for
     cached assets. This is the whole point: avoid re-hashing.
   - For assets not in the cache, process as today (compute dHash, etc.),
     then call `cache?.recordProcessed(...)` and `await
     cache?.maybeCheckpoint()` right after building that asset's
     `PhotoItem`, still inside the existing loop body (this line is what
     makes the checkpoint concurrency-agnostic — see "Checkpoint cadence"
     above; if `fix-scan-performance.md` later restructures this into a
     batched/concurrent shape, these two calls move into whatever
     per-item-completion callback replaces the loop body, not into a new
     top-level place).
   - `onProgress` callback semantics stay the same (`current, total` over
     *all* assets, cached-and-skipped ones included, so the progress bar
     still reflects true overall completion, not just "newly processed this
     run" — matches how the resume banner reports `processed/total`).
   - After the loop, keep the existing final sort (line 79) — this applies
     uniformly to reconstructed-from-cache and newly-processed items alike,
     so ordering is unaffected by which items were cached.

4. **`lib/screens/scan_progress_screen.dart`** changes:
   - Add local state: `ScanCacheSummary? _resumeSummary` and a `bool
     _checkingResume = true` (or similar), populated in `initState` via
     `ScanCacheService().peekSummary()`.
   - Add a `ScanCacheService`-owning field (created once, `load()`ed lazily
     right before a scan starts, whether resuming or fresh — "start over"
     calls `clear()` first).
   - Replace the single "Start Scan" `ElevatedButton` in the idle branch
     (lines 219–229) with conditional UI: if `_resumeSummary != null`, show
     the "Resume scan (X/Y done)" primary button + "Start over" secondary
     button described in UI/UX above; otherwise show today's single button.
   - `_startScan()` (lines 22–67) gains a `{bool resume = true}` parameter
     (or two call sites, `_resumeScan()`/`_startFreshScan()`, whichever
     reads cleaner) — the `resume: false` / "start over" path calls
     `cache.clear()` before invoking `PhotoScannerService.scanAllPhotos`;
     both paths pass the (loaded) `cache` instance through to
     `scanAllPhotos`.
   - After a successful scan (inside the existing `if (photos.isNotEmpty)` /
     `mounted` block around line 42, before or after `provider.finishScan`),
     call `await cache.clear()` per the "finished scan deletes its own save
     point" rule above.
   - No changes needed to the in-progress visual branch (lines 170–193) —
     checkpointing is silent/background as noted.

5. **`lib/main.dart` / `AppStateProvider`** — no structural changes
   required. `AppStateProvider` (lines 34–57) only tracks in-memory
   scanning UI state (`photoGroups`, `isScanning`, `scanProgress`,
   `scanStatus`); it has no persistence responsibilities today and this
   feature doesn't need to add any — `ScanCacheService` is owned/instantiated
   by `ScanProgressScreen` (or passed into it), not by the provider. If a
   later reviewer is tempted to hoist `ScanCacheService` into
   `AppStateProvider` for testability, that's a reasonable follow-up but out
   of scope here — keep this change minimal and localized to the scan
   screen + scanner service.

6. **Tests** — add `test/scan_cache_service_test.dart`:
   - Round-trip: `recordProcessed` N entries, `flush()`, construct a new
     `ScanCacheService`, `load()`, assert `cachedEntries` matches.
   - Resume semantics: given a cache pre-populated with a subset of asset
     ids, assert that "already cached" ids are correctly identified as
     skippable and the "missing" set is exactly `liveIds - cachedIds` (this
     is the core unit under test the task description calls out —
     "resuming with a partial cache skips already-cached IDs").
   - Orphan handling: cache contains an id not present in the live asset
     list; assert reconstruction (whatever helper builds `PhotoItem`s from
     cache + live list) silently omits it, no throw.
   - Corrupt file handling: write garbage bytes / wrong `version` to the
     cache file path, assert `load()` results in an empty cache rather than
     throwing.
   - Checkpoint thresholds: assert `maybeCheckpoint` does *not* write before
     `everyN`/`everyDuration` is reached, and does write once either is
     exceeded (inject a fake clock or keep the duration tiny in the test).
   - These tests need a real filesystem path (use `path_provider_platform_interface`'s
     test mocking, or simpler: have `ScanCacheService` accept an injectable
     `Directory` in its constructor for testability, defaulting to
     `getApplicationSupportDirectory()` in production — this also sidesteps
     needing platform channel mocks in plain `flutter test`). Point the
     injected directory at a temp dir created with `Directory.systemTemp.createTempSync()`
     and clean up in `tearDown`.
   - Keep `test/similarity_service_test.dart` and `test/widget_test.dart`
     untouched/passing.

7. **Verification**:
   - `flutter analyze` — must be clean, no new warnings.
   - `dart format lib/ test/` — format new/changed files.
   - `flutter test` — all tests pass, including the new
     `scan_cache_service_test.dart`.
   - **Manual on-device testing required** (flag this explicitly to
     whoever implements/reviews): automated tests can verify the cache
     service's logic (load/save/skip/orphan/corrupt-file handling) but
     cannot verify true resume-after-process-kill behavior. After
     implementation, manually verify on a real device: start a scan on a
     library large enough to take >10–15 seconds, force-kill the app
     (or use `adb shell am kill <package>` / swipe away from recents)
     mid-scan, relaunch, and confirm the "Resume scan (X/Y done)" prompt
     appears with a sensible X, resuming completes without re-hashing the
     first X photos (can be eyeballed via the existing `print` timing logs
     in `photo_scanner_service.dart`, or a temporary debug counter), and
     "Start over" correctly discards the save point and rescans everything.
     Also manually verify the Android backup-exclusion change (step on
     `AndroidManifest.xml` above) doesn't regress anything else backup-related
     (there is none today, so risk is low, but worth a sanity check that the
     app still installs/runs normally).

## Explicit non-goals for this pass

- No settings-screen exposure of checkpoint cadence (`everyN`/
  `everyDuration`) — hardcode reasonable defaults (100 items / 5 seconds),
  consistent with CLAUDE.md's roadmap noting a settings screen is a
  separate, not-yet-built item.
- No merge-with-previous-completed-scan / incremental re-scan feature —
  that's the separate "Re-scan flow" roadmap item in CLAUDE.md. This
  feature only bridges an *interrupted* scan back to completion; a
  completed scan's cache is deleted, not kept around for future re-scans.
- No change to `PhotoScannerService`'s actual hashing/scoring algorithms or
  to `fix-scan-performance.md`'s concurrency work — this plan is written to
  slot into either the current sequential loop or a future batched/concurrent
  version without modification to the checkpoint call contract itself.
