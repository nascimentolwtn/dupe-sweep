# Fix: Scan Takes ~20 Minutes for 7,000 Photos (Sequential Platform-Channel Calls)

## Bug Summary

Scanning ~7,000 photos on a real device (Samsung S22FE) takes ~20 minutes,
making the app nearly unusable. The scan loop processes photos **one at a
time, fully sequentially, on the main isolate**, and each photo requires two
platform-channel round trips into native Android code
(`thumbnailDataWithSize`, `fileSize`) plus a CPU-bound hash computation. With
nothing overlapping, total wall time is roughly `N x per-photo latency`. At
7,000 photos and ~170ms/photo average, that is the observed ~20 minutes.

This plan fixes the sequential I/O bottleneck by batching photos into
concurrent chunks (`Future.wait`), matching the approach already validated in
this repo's Python prototype (`ThreadPoolExecutor(max_workers=16)`). It does
**not** reintroduce a background isolate for the platform-channel calls,
because that was already tried and reverted (see "Why not isolates" below).

## Confirmed Current State (read 2026-08-13)

### `lib/services/photo_scanner_service.dart` — `scanAllPhotos` (lines 8-87)

- Lines 16-20: attempts `BackgroundIsolateBinaryMessenger.ensureInitialized(...)`
  in a try/catch — this is a leftover from when the method was expected to
  run inside a `compute()` isolate. It is currently called from the main
  isolate (confirmed below), so this call is a harmless no-op today (it just
  logs "already initialized or main thread"). Leave it as-is or remove it —
  either way it must **not** be relied upon as isolate setup, since the
  method is not run in an isolate.
- Lines 50-76: the hot loop.
  ```
  for (int i = 0; i < allAssets.length; i++) {
    final asset = allAssets[i];
    final createDateTime = asset.createDateTime ?? DateTime.now();

    String? dhash;
    try {
      final thumbData = await asset.thumbnailDataWithSize(
        const ThumbnailSize(200, 200),
      );                                          // platform-channel call #1
      if (thumbData != null) {
        dhash = SimilarityService.computeDHash(thumbData); // CPU-bound, sync
      }
    } catch (e) {
      print('Error computing hash for ${asset.id}: $e');
    }

    photos.add(PhotoItem(
      id: asset.id,
      path: asset.relativePath ?? 'Unknown',
      createDateTime: createDateTime,
      fileSize: await asset.fileSize,              // platform-channel call #2
      dhash: dhash,
    ));

    onProgress?.call(i + 1, allAssets.length);
  }
  ```
  Each iteration fully `await`s call #1, then runs `computeDHash` inline
  (blocks the event loop for the duration of the image decode/resize/hash),
  then fully `await`s call #2, before starting the next photo. Nothing is
  in flight concurrently.
- Line 79: `photos.sort((a, b) => a.createDateTime.compareTo(b.createDateTime))`
  runs once, after the loop, on the fully-collected list — unaffected by
  batching as long as the final `photos` list is complete before this line
  runs (order of insertion into `photos` does not matter, since it's sorted
  immediately after).

### Call site: `lib/screens/scan_progress_screen.dart` — `_startScan` (lines 22-67)

- Line 28-32: calls `PhotoScannerService.scanAllPhotos(onProgress: ...)`
  directly on the main isolate (comment on line 27: "Run scan on main thread
  to avoid isolate platform channel issues"). `onProgress` currently maps
  `(current, total)` to `provider.updateProgress(current / total, 'Scanning:
  $current/$total')` (line 30) — a 1:1 "N photos done out of total" contract
  that must be preserved in spirit (smooth, monotonically-increasing
  progress), even though the loop internals change.
- No `compute()` call exists here today. This confirms `scanAllPhotos` runs
  entirely on the main isolate right now, matching the CLAUDE.md note under
  Services Layer #1 and the commit that removed the isolate.

### Why not isolates — git history

Commit `cdd528d` ("Add manual scan button, fix isolate blocker by running
scan on main thread") deliberately removed a `compute()`-based isolate call
because it "caused platform channel access issues." Its diff shows the
`BackgroundIsolateBinaryMessenger.ensureInitialized(...)` call was added at
that time as a defensive measure for when the method *might* run in a
background isolate, but the actual fix was to stop calling
`scanAllPhotos` via `compute()` from the screen and call it directly instead.

**This plan must not reintroduce `compute()` around `scanAllPhotos` or around
the per-photo `thumbnailDataWithSize`/`fileSize` calls.** Those platform
calls must keep running on the main isolate's platform channel, exactly as
they do today — only the *sequencing* changes (concurrent chunks instead of
one-at-a-time), not the *isolate* they run on.

### Investigation: does `photo_manager` support concurrent in-flight calls?

Read `photo_manager` package source directly (installed version, confirmed
via `pubspec.lock`: `photo_manager: 3.12.0` — note CLAUDE.md's dependency
list says `^2.7.0`, that section of CLAUDE.md is stale/out of date, not a
concern for this bug fix), at
`<pub-cache>/hosted/pub.dev/photo_manager-3.12.0/lib/src/types/entity.dart`:

- `AssetEntity.thumbnailDataWithSize(...)` (line 684) is a plain `Future`-
  returning method with no locking, no queue, no "only one at a time" guard
  in the Dart wrapper. It delegates through `thumbnailDataWithOption` to the
  plugin, which ultimately issues a standard Flutter `MethodChannel`
  `invokeMethod` call (channel object constructed in
  `lib/src/internal/plugin.dart` line 27, `MethodChannel _channel = const
  PMMethodChannel(PMConstants.channelPrefix)`).
- `AssetEntity.fileSize` (line 778) is `Future<int> get fileSize =>
  plugin.getFileSize(this);` — same pattern, another plain method-channel
  call.
- Flutter's `MethodChannel.invokeMethod` is designed to support multiple
  concurrent in-flight calls: each call gets its own reply handle managed by
  the `BinaryMessenger`, and calls do not block each other Dart-side. This is
  standard, well-established Flutter behavior (not specific to
  `photo_manager`) — it is how e.g. `http` or `dio` packages achieve
  concurrent network requests through platform channels on iOS/Android too.
- Nothing in the package source, CHANGELOG, or the reverted commit's error
  message suggests `photo_manager` calls must be serialized. The isolate
  problem in `cdd528d` was about **calling the platform channel from a
  non-root isolate without proper `BackgroundIsolateBinaryMessenger`
  registration** (a separate, real Flutter constraint — platform channels
  must run on an isolate that either is the root isolate or has explicitly
  registered itself via `BackgroundIsolateBinaryMessenger.ensureInitialized`
  with the root isolate token) — **not** about concurrency/ordering of calls
  from the same (root) isolate. Firing multiple `Future`s from the main
  isolate via `Future.wait` never leaves the root isolate, so this
  constraint does not apply and the original bug cannot recur from this
  change.

**Conclusion**: concurrent in-flight `thumbnailDataWithSize`/`fileSize` calls
from the main isolate are safe and are exactly the mechanism that makes the
Python `ThreadPoolExecutor` reference fast (overlapping I/O wait time, not
CPU parallelism). No isolate is needed to get this speedup.

### `lib/services/similarity_service.dart` — `computeDHash` (lines 38-66)

CPU-bound: `img.decodeImage`, `img.copyResize` to 9x8, `img.grayscale`, then
a 64-bit pairwise-luminance-compare loop. This runs synchronously on whatever
isolate calls it. Currently called inline in the main-isolate loop (line 61
of `photo_scanner_service.dart`), so every hash decode blocks the UI thread
briefly. At 200x200 thumbnail input size this is cheap per-call (a handful
of milliseconds), but across 7,000 photos it adds up and, unlike the
I/O-bound calls, batching alone does not overlap it — it's synchronous CPU
work that will still serialize inside whatever isolate runs it.

**Decision for this pass**: keep `computeDHash` on the main isolate,
per-item, same as today. Do not move it to `compute()`/a separate isolate in
this fix. Reasoning:
- The dominant cost (per the bug report and the ~170ms/photo average) is the
  platform-channel round trips, not the hash math — fixing those first is
  the highest-leverage, lowest-risk change.
- Moving `computeDHash` to an isolate means marshalling the decoded
  `Uint8List` thumbnail bytes across isolate boundaries (cheap, `Uint8List`
  is transferable) but adds isolate-pool management complexity, and stacking
  that on top of a first isolate-related change in the same PR that already
  caused one regression (`cdd528d`) raises risk for a second one. Do it as a
  separate, later, measured optimization if profiling after this fix shows
  CPU-bound hashing (not I/O wait) is still a meaningful fraction of total
  time.
- **Stretch goal (explicitly out of scope for the initial implementation,
  note but do not build)**: if a follow-up wants to move `computeDHash` off
  the main isolate, use `Isolate.run(() => SimilarityService.computeDHash(bytes))`
  (Dart 2.19+, simpler than manual `compute()`/isolate setup, no
  platform-channel involvement since it only touches the already-fetched
  `Uint8List` and the `image` package — no `BackgroundIsolateBinaryMessenger`
  registration needed because this isolate never touches a platform
  channel). This sidesteps the original `cdd528d` failure mode entirely,
  because the risk there was platform-channel access from a non-root
  isolate, and `computeDHash` never touches a platform channel. Flag this
  explicitly for a future pass; do not implement in this fix.

## The Fix

### Design: chunked concurrency via `Future.wait`

Replace the single sequential `for` loop (lines 50-76) with a loop over
fixed-size chunks of `allAssets`, where each chunk's photos are processed
concurrently via `Future.wait`, and chunks themselves are processed
sequentially (chunk N+1 does not start until chunk N fully completes).

- **Chunk size**: start with **16** concurrent in-flight requests per chunk,
  matching the Python reference's `ThreadPoolExecutor(max_workers=16)`
  exactly (`python-mvp1/find_duplicate_photos.py` line 204) — this value is
  already empirically validated against real device I/O characteristics on
  this exact use case. Make it a named constant (e.g. `_kScanConcurrency =
  16`) local to `photo_scanner_service.dart` so it is easy to tune later; no
  need to expose it as a public parameter or settings-screen value in this
  pass (CLAUDE.md roadmap already lists a settings screen as a separate,
  not-yet-built item — don't scope-creep into it here).
- **Per-photo unit of work**: extract the current loop body (lines 51-75)
  into a private async helper, e.g. `static Future<PhotoItem>
  _processAsset(AssetEntity asset)`, that does exactly what one loop
  iteration does today (fetch thumbnail, compute hash, fetch file size,
  build and return one `PhotoItem`) but does **not** call `onProgress` itself
  — progress reporting moves to the chunk-driving code (see below) so it can
  fire per-completed-item, not per-chunk.
- **Chunking loop**:
  ```
  for each chunk of allAssets (size _kScanConcurrency):
    fire _processAsset(asset) for every asset in the chunk as a Future
    as each one completes, add its PhotoItem to `photos` and call
      onProgress?.call(completedSoFar, allAssets.length)
    await all of them (Future.wait) before moving to the next chunk
  ```
  To get **per-item** progress callbacks (not one jump per chunk of 16), do
  not use bare `Future.wait(chunk.map(_processAsset))` and call `onProgress`
  once after — instead wrap each future so it reports its own completion,
  e.g. attach a `.then((photo) { photos.add(photo); completed++;
  onProgress?.call(completed, allAssets.length); return photo; })` to each
  per-asset future before passing the list to `Future.wait`. This makes the
  progress bar advance smoothly item-by-item even though up to 16 requests
  are in flight at once, matching the existing UX (`ScanProgressScreen`
  line 30 expects `current/total` to increase roughly one-by-one, not jump
  in steps of 16).
- **Ordering**: `photos` will no longer necessarily fill in the same order
  as `allAssets` within a chunk (whichever of the 16 in-flight requests
  finishes first gets added first) — this is fine and already handled,
  since line 79's `photos.sort((a, b) =>
  a.createDateTime.compareTo(b.createDateTime))` sorts the complete list by
  capture time immediately after the loop regardless of insertion order.
  Verify no other code downstream depends on `photos` being asset-list-order
  before the sort (checked: `scan_progress_screen.dart`'s `_groupPhotosByDay`
  and friends only consume the already-sorted `photos` list passed back from
  `scanAllPhotos`, so this is safe).
- **Error handling**: preserve the existing per-photo try/catch around hash
  computation (lines 56-65) inside `_processAsset` — a single photo's hash
  failure must not abort its chunk's `Future.wait` or the whole scan, exactly
  as today's per-iteration try/catch means one bad photo doesn't kill the
  loop. Ensure `_processAsset` itself doesn't let an uncaught exception from
  `asset.fileSize` propagate and fail the whole `Future.wait` for its
  chunk — either wrap the whole method body in try/catch and return a
  `PhotoItem` with sensible fallback fields (e.g. `fileSize: 0`) on failure,
  mirroring the top-level `catch (e)` in `scanAllPhotos` (lines 82-86) that
  already returns `[]` for a total failure — decide fallback fields during
  implementation, but do not let one photo's platform-call failure drop it
  from the scan silently in a way that produces a shorter `photos` list than
  `allAssets` (that would desync any future "processed count" logic, and
  matters for the planned save-points feature described below).

### Why chunks of fixed size (vs. unbounded `Future.wait(allAssets.map(...))`)

Firing all ~7,000 requests at once via a single unbounded `Future.wait` was
considered and rejected: uncontrolled concurrency against native Android
platform channels and the underlying MediaStore/thumbnail-decode subsystem
could exhaust native-side resources (thread pool starvation, memory pressure
from thousands of in-flight thumbnail buffers) in ways that are hard to
predict without on-device profiling, and provides no way to bound memory
growth or produce smooth progress. Bounded chunking (16 at a time,
matching the already-validated Python worker count) gets the same
overlap-driven speedup with predictable, bounded resource usage.

### Interaction with the planned "Scan save points" feature

`.claude/plans/scan-save-points.md` (already written, not yet implemented)
explicitly designs its checkpoint mechanism to be concurrency-agnostic: it
calls for a `recordProcessed(...)` + `maybeCheckpoint()` pair to be invoked
"from wherever an individual photo finishes being hashed/scored" — i.e. from
a per-item completion callback, not assuming strict sequential ordering.
The `.then((photo) { ... })` per-item completion hook introduced by this fix
(above) is exactly that hook: when save-points is implemented later, its two
calls slot into the same `.then(...)` callback right next to the
`onProgress?.call(...)` line, with no restructuring of this fix's loop
shape required. Do not build save-point logic in this pass — just don't
collapse the per-item completion point back down to a per-chunk-only
callback, or that future integration point disappears.

Scan-performance (this plan) should land **before** scan-save-points, since
save-points' implementation steps reference "whatever
per-item-completion callback replaces the loop body" — i.e. it expects this
fix's shape to already exist.

## Implementation Steps

1. **`lib/services/photo_scanner_service.dart`** — the only file requiring
   code changes:
   a. Add a private constant near the top of the class: `static const int
      _kScanConcurrency = 16;`
   b. Extract lines 51-75's loop body into a new private static method
      `static Future<PhotoItem> _processAsset(AssetEntity asset)` that:
      - Computes `createDateTime` (same fallback to `DateTime.now()`).
      - Fetches thumbnail data, computes `dhash` with the same try/catch
        around `SimilarityService.computeDHash` (preserve the existing
        `print('Error computing hash for ${asset.id}: $e')` log).
      - Fetches `fileSize`.
      - Returns a fully-built `PhotoItem` (do not call `onProgress` inside
        this method — that's the caller's job now).
      - Wrap the whole method body defensively (see "Error handling" above)
        so a single asset's platform-call failure can't crash its chunk.
   c. Replace the `for (int i = 0; ...)` loop (lines 50-76) with the
      chunked-concurrency loop described in "Design" above: iterate
      `allAssets` in slices of `_kScanConcurrency`, build a list of
      `_processAsset(asset).then((photo) { photos.add(photo); completed++;
      onProgress?.call(completed, allAssets.length); return photo; })`
      futures for the slice, `await Future.wait(...)` on that list before
      moving to the next slice. Track `completed` as a local `int` counter
      initialized to `0` before the outer loop.
   d. Leave everything else unchanged: the album/asset-count fetching (lines
      22-47), the final sort (line 79), the top-level try/catch and return
      `[]` on total failure (lines 11, 82-86), and the
      `BackgroundIsolateBinaryMessenger.ensureInitialized` no-op block
      (lines 14-20) — leave it in place since it's harmless and removing it
      is not necessary to fix this bug (avoid unrelated churn).
   e. Do not introduce `compute()`, `Isolate.run`, or any isolate spawning
      anywhere in this file for this pass — see "Why not isolates" above.

2. **No changes needed to `lib/screens/scan_progress_screen.dart`.** Its
   `onProgress: (current, total) => provider.updateProgress(current / total,
   'Scanning: $current/$total')` callback (line 29-31) works unchanged
   against the new chunked loop, since `onProgress` is still called with
   `(completed, total)` semantics — just more frequently interleaved (from
   `.then()` callbacks across up to 16 in-flight futures) instead of
   strictly one-at-a-time. No signature change, no call-site change.

3. **No changes needed to `lib/models/photo_item.dart`** — `PhotoItem`'s
   constructor and fields are unaffected; `_processAsset` builds the same
   shape of object the old loop body did.

4. **No changes needed to `lib/services/similarity_service.dart`** —
   `computeDHash` stays as-is, called the same way (synchronously, given
   already-fetched thumbnail bytes), just now called from inside
   `_processAsset` instead of inline in the old loop.

5. **Tests**: `test/similarity_service_test.dart` exercises
   `SimilarityService` directly (clustering, hamming distance, hash
   grouping) and does not touch `PhotoScannerService` at all — no changes
   needed there, and it should continue to pass unmodified. There is
   currently no dedicated test file for `PhotoScannerService` (it requires
   `photo_manager` platform channels, which aren't available under plain
   `flutter test` without mocking `photo_manager`'s platform interface) —
   adding a full mocked-platform-channel test harness for
   `PhotoScannerService` is out of scope for this fix (it would be a
   pre-existing gap, not a regression introduced here). If time permits,
   optionally add a narrow test that stubs `_processAsset` behavior at the
   chunking-logic level (e.g. extract the "process a list of arbitrary
   futures in chunks of N with per-item progress callbacks" logic into a
   small, platform-independent helper — a stretch goal, not required to
   close this bug).

6. **Verification**:
   - `flutter analyze` — must be clean, no new warnings introduced by the
     refactor.
   - `dart format lib/services/photo_scanner_service.dart` (and any other
     touched files).
   - `flutter test` — full suite passes, especially
     `test/similarity_service_test.dart` unchanged/green.
   - **Manual on-device timing is the real verification for this bug and
     cannot be done by an automated agent.** After implementing, ask the
     user to:
     1. Run the app on the Samsung S22FE (or another real device with a
        comparably large library, ideally the same ~7,000-photo library
        used to observe the original ~20 minute scan).
     2. Time a full scan from tapping "Start Scan" to the review screen
        appearing, and compare against the ~20 minute baseline. A
        successful fix should bring this down by roughly an order of
        magnitude (expect low single-digit minutes, though exact speedup
        depends on device I/O characteristics and network/storage state —
        report the actual observed number rather than assuming a specific
        target).
     3. Confirm the progress bar during the scan still advances smoothly
        (no long freezes, no jumping in visible chunks of 16) — this
        validates the per-item `.then()` progress hook is working as
        designed, not silently degrading to per-chunk updates.
     4. Confirm the final duplicate groups/counts look sane and comparable
        to a pre-fix scan of the same library (i.e. the concurrency change
        didn't silently drop or duplicate any photos) — spot check total
        photo count matches the device's actual library size.
     5. Watch for any new errors/crashes in `flutter logs` during the scan,
        particularly around `thumbnailDataWithSize`/`fileSize` calls, which
        would indicate the concurrency level (16) needs to be tuned down.

## Explicit Non-Goals For This Pass

- No isolate for `computeDHash` (CPU-bound hashing) — noted as a flagged
  future stretch goal above, not built here.
- No settings-screen exposure of concurrency level — hardcoded constant
  (`_kScanConcurrency = 16`), consistent with CLAUDE.md's roadmap noting a
  settings screen is a separate, not-yet-built item.
- No scan save-points / pause-resume logic — that's
  `.claude/plans/scan-save-points.md`, a separate, already-written plan that
  depends on this one landing first. This plan only needs to avoid
  structuring the loop in a way that conflicts with that later work (see
  "Interaction with the planned Scan save points feature" above).
- No change to clustering/grouping algorithms (`SimilarityService`,
  `ScanProgressScreen`'s day/hash grouping) — that's a separate concern
  (see `.claude/plans/fix-time-window-grouping.md` if relevant), unaffected
  by this performance fix.
