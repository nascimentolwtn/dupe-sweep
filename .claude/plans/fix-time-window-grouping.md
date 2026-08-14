# Fix: Photo Grouping Uses Calendar-Day Buckets Instead of Rolling Time Window

## Bug Summary

The Android app groups photos by **calendar day** (midnight-to-midnight), not by
the rolling time-gap clustering used in the validated Python reference
(`python-mvp1/find_duplicate_photos.py`). This causes two problems:

1. **Missed duplicates at day boundaries**: photos taken at 23:59 and 00:01 (2
   minutes apart) land in different groups and never get hash-compared.
2. **Over-broad hash comparison within a day**: every photo taken on the same
   calendar day (which could span unrelated events at 8am, 1pm, 9pm) gets
   Hamming-compared against every other photo from that day before any
   splitting happens.

A correct, gap-based implementation already exists in `SimilarityService` but
is never called by the screen that builds the review groups. The screen has
its own drifted, inline duplicate of the hash-grouping logic instead.

## Confirmed Current State (read 2026-08-13)

### The bug: `lib/screens/scan_progress_screen.dart`

- `_groupPhotosByDay` (lines 69–96): buckets photos into calendar days via
  `_getDateOnly` (lines 158–160), comparing `DateTime(y,m,d)` equality — not a
  rolling gap.
- `_addHashGroups` (lines 98–147): inline copy of hash sub-grouping logic,
  greedy nearest-to-first grouping with `distance <= 10` hardcoded, called per
  calendar-day bucket. Handles the `dayPhotos.length == 1` case specially
  (line 107) and sets `groupType: subGroup.length > 1 ? 'hash' : 'single'`
  (line 143).
- `_hammingDistance` (lines 149–156): inline duplicate of Hamming distance
  calculation, character-by-character string compare (same algorithm as
  `SimilarityService.hammingDistance` but a separate copy that can drift).
- Called from `_startScan` (line 44): `final groups = _groupPhotosByDay(photos);`
  then `provider.finishScan(groups);` (line 49).
- Input `photos` is already sorted by `createDateTime` ascending — see
  `PhotoScannerService.scanAllPhotos`, line 79: `photos.sort((a, b) =>
  a.createDateTime.compareTo(b.createDateTime));`. This sort is a
  precondition for gap-based clustering to work correctly.

### The correct, unused implementation: `lib/services/similarity_service.dart`

- `clusterByTime` (lines 11–34): rolling-gap clustering. Walks the
  **already-sorted** list; starts a new cluster whenever the gap to the
  *previous* photo exceeds `timeWindowSeconds` (default
  `defaultTimeWindowSeconds = 120`, line 6). This matches the Python
  `cluster_by_time` gap semantics (`find_duplicate_photos.py:120-131`), with
  one difference noted below.
- `hammingDistance` (lines 69–79): standalone, correct, already unit-tested.
- `groupBySimilarity` (lines 82–115): sub-groups a list of photos by Hamming
  distance against a `Map<String, String> photoHashes` (photo id → hash),
  default threshold `defaultHammingDistanceThreshold = 10` (line 7). Greedy
  "compare against first-added representative-ish" grouping — actually
  compares against the *group's original seed photo* only implicitly via
  first-pass containment (re-read before implementing; see Step 3 note).

### Divergence from Python reference (informational, do not silently "fix" — see Step 3)

- Python's `cluster_by_time` (`find_duplicate_photos.py:120-131`) and
  `split_by_similarity` (`find_duplicate_photos.py:134-152`) both **drop
  singleton groups** (`if len(c) > 1` / `if len(g) > 1`) — a photo with no
  time-neighbor or no hash-neighbor never appears in the output at all.
- Dart's `SimilarityService.clusterByTime` and `groupBySimilarity` **do not
  filter singletons** — every photo ends up in some cluster/group, even if
  it's alone.
- The current buggy `scan_progress_screen.dart` also does **not** filter
  singletons: a lone photo becomes its own `PhotoGroup` with `groupType:
  'single'` (or default `'time'` for a whole day of 1 photo). So keeping
  singleton groups is consistent with **existing app behavior** — this is not
  a regression to fix here, just a documented divergence from the Python
  script. Flag as a follow-up decision, not in scope.

### Data models (no changes needed)

- `lib/models/photo_item.dart`: `PhotoItem` has `id`, `path`, `createDateTime`,
  `fileSize`, `dhash`, plus scoring/selection fields. No changes required.
- `lib/models/photo_group.dart`: `PhotoGroup` constructor takes `id` (String,
  required), `photos` (List<PhotoItem>, required), `timestamp` (DateTime,
  required), `groupType` (String, default `'time'`). No changes required —
  reuse as-is.

### Existing tests: `test/similarity_service_test.dart`

Already exercises `SimilarityService` directly and passes today:
- `clusterByTime`: within-window clustering, empty list, single photo, custom
  window (lines 8–89).
- `hammingDistance`: basic distance, identical hashes, max distance,
  mismatched lengths, empty hashes (lines 93–131).
- `groupBySimilarity`: groups by threshold, photos with no hash, empty list
  (lines 135–209).

These tests validate the service logic in isolation but **do not exercise
`scan_progress_screen.dart`** at all, since that screen never calls
`SimilarityService`. That's the actual bug: correct logic exists and is
tested, but the app doesn't use it.

## Fix Design

Replace the screen's inline day-bucketing + inline hash grouping with calls
into `SimilarityService.clusterByTime` + `SimilarityService.groupBySimilarity`,
and delete the drifted inline copies.

### New grouping flow in `scan_progress_screen.dart`

Replace `_groupPhotosByDay` (and its helpers `_addHashGroups`,
`_hammingDistance`, `_getDateOnly`) with a single method, e.g.
`_buildPhotoGroups(List<PhotoItem> photos)`, that:

1. Calls `SimilarityService.clusterByTime(photos)` using the default
   `timeWindowSeconds` (do not pass a literal `120` — let the service default
   apply, so there is exactly one place the default lives).
2. For each returned time cluster (`List<PhotoItem>`):
   - If the cluster has 1 photo, wrap it directly in a `PhotoGroup` with
     `groupType: 'time'` (or `'single'`, matching current terminology) — no
     need to call hash grouping on a single photo.
   - If the cluster has 2+ photos, build the `Map<String, String>
     photoHashes` from the cluster's photos (`{ for (p in cluster) if
     (p.dhash != null && p.dhash!.isNotEmpty) p.id: p.dhash! }`) and call
     `SimilarityService.groupBySimilarity(cluster, photoHashes: photoHashes)`
     using the default `hammingThreshold`.
   - For each resulting sub-group (`List<PhotoItem>`), construct a
     `PhotoGroup` with a generated `id`, `photos: subGroup`, `timestamp`
     (use the timestamp of the cluster/sub-group's first photo — preserve
     current convention of using a representative `DateTime`, not
     necessarily calendar-day-truncated), and `groupType: subGroup.length >
     1 ? 'hash' : 'single'` (matches existing convention at old line 143).
3. Return the flattened `List<PhotoGroup>`.

Keep ID generation simple and collision-free — e.g. a running integer counter
across the whole method (`'group_$i'`), incremented per emitted `PhotoGroup`.
The old code's "reserve ID ranges per day" scheme (line 85,
`groupIndex += currentDayPhotos.length ~/ 2 + 1`) was a workaround for
composing two loops; a single flat counter in one pass is simpler and
equivalent, since the old scheme was never guaranteed collision-free anyway.

### Why not just fix `_groupPhotosByDay` in place

Because the bug is architectural, not a one-line condition swap: the entire
day-bucket concept must be removed, and the inline hash/Hamming logic must be
deleted in favor of the existing tested service methods — otherwise the
drift between `scan_progress_screen.dart`'s copy and
`similarity_service.dart`'s copy remains a standing risk (the stated root
cause).

### Time window / Hamming threshold configurability

- Do **not** hardcode `120` or `10` as new literals in
  `scan_progress_screen.dart`. Call `SimilarityService.clusterByTime(photos)`
  and `SimilarityService.groupBySimilarity(cluster, photoHashes: photoHashes)`
  with no explicit `timeWindowSeconds` / `hammingThreshold` arguments, so
  they fall through to `SimilarityService.defaultTimeWindowSeconds` and
  `SimilarityService.defaultHammingDistanceThreshold`.
- This keeps exactly one source of truth for the defaults (already in
  `similarity_service.dart` lines 6–7) and means a future Settings screen
  only needs to thread `timeWindowSeconds` / `hammingThreshold` values from
  provider state down into these two call sites — no rework of the grouping
  logic itself.
- Do not build any Settings UI or persistence in this fix.

## What NOT to Touch

- Do not modify `lib/services/photo_scanner_service.dart` — scanning and
  sorting-by-`createDateTime` are already correct and are a precondition for
  `clusterByTime` to work.
- Do not change the hash algorithm (`SimilarityService.computeDHash`,
  dHash/gradient-based). The fact that it differs from Python's DCT-based
  `imagehash.phash` is a **separate, secondary risk** — note it in code
  review / follow-up only if match quality still looks wrong after this fix
  lands. Do not attempt to port or reconcile the two hash algorithms as part
  of this change.
- Do not change `PhotoGroup` or `PhotoItem` models.
- Do not change `SimilarityService.clusterByTime` / `groupBySimilarity` /
  `hammingDistance` — they are already correct and already tested. Reuse
  as-is.
- Do not build a Settings screen or expose the time window / Hamming
  threshold as user-configurable in this change (tracked separately in the
  roadmap backlog per `CLAUDE.md`).
- Do not change the singleton-group filtering behavior (i.e. do not start
  dropping single-photo groups to match the Python script) — that's a
  distinct UX decision, out of scope, and would change what appears in
  "Review Duplicates" beyond this bug's blast radius.

## Implementation Steps

1. **Read current state once more immediately before editing** —
   `lib/screens/scan_progress_screen.dart` line numbers may have shifted if
   other work landed between this plan being written and being executed.
   Re-locate `_groupPhotosByDay`, `_addHashGroups`, `_hammingDistance`,
   `_getDateOnly` by name/signature rather than trusting line numbers
   blindly.

2. **Add the import** for `SimilarityService` in
   `lib/screens/scan_progress_screen.dart`
   (`import '../services/similarity_service.dart';`), alongside the existing
   `photo_group.dart` / `photo_item.dart` imports (lines 4–5).

3. **Replace the grouping method**: remove `_groupPhotosByDay`,
   `_addHashGroups`, `_hammingDistance`, and `_getDateOnly` in their entirety
   and add the new `_buildPhotoGroups` method described above (time-cluster
   via `SimilarityService.clusterByTime`, then hash-subgroup each cluster via
   `SimilarityService.groupBySimilarity`, constructing `PhotoGroup`s from the
   result).

4. **Update the call site** in `_startScan` (around old line 44): change
   `final groups = _groupPhotosByDay(photos);` to
   `final groups = _buildPhotoGroups(photos);` (or whatever name was used in
   Step 3). Leave the surrounding logging (`print('[SCAN] Created ${groups.length}
   groups')`, per-group `print('[GROUP] ...')`, `provider.finishScan(groups)`,
   navigation to `DuplicateReviewScreen`) untouched.

5. **Verify no other file references the removed private methods.** They are
   private (`_`-prefixed) to `_ScanProgressScreenState`, so this should only
   be a concern within the same file — confirm with a search for
   `_groupPhotosByDay`, `_addHashGroups`, `_hammingDistance`, `_getDateOnly`
   across `lib/` and `test/` before deleting, in case a widget test
   references them directly (unlikely given they're private, but verify).

6. **Add/update a test that exercises the screen's actual grouping path**,
   not just the service in isolation. Existing
   `test/similarity_service_test.dart` coverage of `clusterByTime` /
   `groupBySimilarity` / `hammingDistance` stays as-is (still valid, still
   useful as the underlying algorithm contract). In addition:
   - If `_buildPhotoGroups` remains a private method on
     `_ScanProgressScreenState`, it can't be unit-tested directly from
     outside the file. Two options, pick whichever is simplest at
     implementation time:
     - (a) Extract the grouping method as a `static` (or top-level) function
       in `scan_progress_screen.dart` that takes `List<PhotoItem>` and
       returns `List<PhotoGroup>`, with no `State`/`BuildContext`
       dependency, so a test file can import and call it directly with a
       synthetic photo list spanning a day boundary (e.g. photos at 23:59
       and 00:01, 2 minutes apart) and assert they land in the **same**
       group — this is the concrete regression test for the bug.
     - (b) If keeping it as a private instance method is preferred, add a
       widget test that pumps `ScanProgressScreen`... but this is
       significantly more complex (requires mocking `PhotoScannerService`
       and `photo_manager` platform channels) and is not recommended as the
       primary test. Prefer (a).
   - Recommended: prefer (a). Add a new test file
     `test/scan_progress_grouping_test.dart` (or add a group to
     `test/similarity_service_test.dart` if the extracted function is moved
     there instead — see note below) with at least:
     - A test with photos at `23:59:00` and `00:01:00` (day boundary, 2
       minutes apart) asserting they are clustered together (regression test
       for the exact bug described).
     - A test confirming that photos spanning a wide same-day range (e.g.
       09:00 and 21:00, same calendar day) end up in **different** groups
       (regression test proving the old day-bucket behavior is gone).
   - Optional stronger check: assert that the flattened result of
     `_buildPhotoGroups(photos)` (or the extracted function) matches what you
     get by manually calling `SimilarityService.clusterByTime(photos)` then
     `SimilarityService.groupBySimilarity(...)` per cluster and comparing
     photo-id sets — this directly proves the screen delegates to the real
     service rather than reimplementing it.

7. **Run verification, in this order:**
   - `flutter analyze` — must be clean (no new warnings/errors from removed
     methods, unused imports, etc.).
   - `flutter test` — all existing tests in `test/similarity_service_test.dart`
     must still pass unmodified; new test(s) from Step 6 must pass.
   - `dart format lib/ test/` — apply formatting to touched files.
   - Manual/behavioral sanity check (if a device/emulator is available): run
     the app, scan a library containing photos taken close together across a
     day boundary if possible, and confirm they now appear in the same
     review group. If no such test data is available on-device, the
     regression test from Step 6 is the primary verification.

8. **Do not touch** `python-mvp1/find_duplicate_photos.py` — it is the
   read-only reference implementation, not part of the Flutter app.

## Open Questions / Follow-ups (do not resolve in this fix)

- **Hash algorithm mismatch**: Dart's dHash (gradient-based, 64-bit,
  `similarity_service.dart:38-66`) vs. Python's `imagehash.phash` (DCT-based)
  are different algorithms; a Hamming threshold of `10` is not necessarily
  equivalent perceptual "closeness" for both. If match quality still looks
  wrong after this fix (e.g. genuinely different photos grouped together, or
  near-duplicates still missed), investigate the threshold/algorithm as a
  separate follow-up — do not fold that investigation into this fix.
- **Singleton group filtering**: whether `PhotoGroup`s containing a single,
  non-duplicate photo should be filtered out of `provider.finishScan(groups)`
  (matching Python's `len(c) > 1` / `len(g) > 1` filtering, and matching the
  "No duplicates found" empty state in `duplicate_review_screen.dart` line
  24, which currently can't ever trigger once photos exist, since
  singleton groups are always emitted) is a real product-behavior question,
  out of scope here, but worth flagging to the user/product owner separately.
- **Configurable time window / Hamming threshold**: tracked in `CLAUDE.md`
  roadmap as a planned Settings screen item. This fix intentionally keeps the
  two values as `SimilarityService` static defaults so that future work only
  needs to thread parameters through, not restructure grouping logic.
