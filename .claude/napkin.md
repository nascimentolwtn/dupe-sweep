# Napkin Runbook

## Curation Rules
- Re-prioritize on every read.
- Keep recurring, high-value notes only.
- Max 10 items per category.

## Current Status: Hash-Based Duplicate Detection ✅

**WORKING**: Scanning, hash computation, and perceptual grouping all working on main thread.
- Scan button triggers PhotoScannerService
- Computes dHash on thumbnails (fast, 200x200)
- Groups photos by date, then sub-groups by Hamming distance (threshold=10)
- Progress shows during scan

**Notes for next session**:
- Main thread scan is responsive on small-medium libraries (tested on Samsung S21)
- For very large libraries (10k+ photos), consider UI progress updates
- Hash computation works correctly but verify grouping with real duplicates

---

## Feature Development Pipeline (Priority Order)

### 1. Hash-Based Grouping Integration ✅ DONE
Integrate dHash (already computed in SimilarityService) into the review UI.
- **Status**: COMPLETE - Scanning, hashing, and sub-grouping all working
- **Implementation**: PhotoScannerService computes hashes during scan, ScanProgressScreen shows progress, groups use hash-based sub-clustering

### 2. Real-device bugs from 2026-08-13/14 session ✅ ALL FIXED
Grouping-vs-python-mvp1 mismatch, ~20min scan time, no save points, hard-to-scroll
list, permission re-prompt, negative-hash grouping bug, delete not syncing the
list (context-shadowing), isBest not re-elected after delete, silent scan-failure-
as-success. See git log (commits `1541d84`..`805e12b`) for details on each.

### 3. Opus code-review: remaining Medium/Low findings ✅ ALL FIXED
Fixed in `06ecab0` (Medium/Low bugs) + `7f65c62` (ValueKey fix bundled in).
Verified against code 2026-08-14: FutureBuilder memoization
(`photo_group_card.dart`'s `_thumbnailFuture`), `scoring_service.dart` v4
API + overflow fix, `groupBySimilarity` no-hash handling, delete
partial-failure feedback (`summary_bar.dart`), `mounted` guards, `ValueKey`s
on `PhotoGroupCard`/`duplicate_review_screen.dart`, `ScanCacheService`
`clear()`/`flush()` race + `peekSummary()` isolation, `_startScan`
re-entrancy guard, and both nitpicks (unused import, write-only field) —
all present.

### 4. Fix all Cursor IDE / `flutter analyze` problems ✅ DONE
`flutter analyze` → "No issues found!" (verified 2026-08-14). Fixed in
`d06a14e` (test/widget_test.dart rewrite, analysis_options.yaml cleanup) +
the debugPrint sweep bundled into `06ecab0`. No `print(` calls remain
anywhere in `lib/`.

### 5. Scoring UI Integration
Auto-select "best" photo in each group based on real sharpness + exposure
scoring instead of the current largest-file-size stopgap (`PhotoGroup.
ensureBestElected`).
- **Impact**: More accurate default pick than file size alone.
- **Blocked on**: `scoring_service.dart` needs the image v4 API fix (item 3) first.
- **Effort**: Low once unblocked — call scoring during Phase 2, feed into
  `ensureBestElected`'s selection instead of file size.

### 6. Settings Screen
Expose configurable time window (default 120s) and Hamming distance threshold (default 10).
- **Impact**: Lets power users fine-tune grouping behavior
- **Effort**: Medium—add new screen, wire to state management, persist to SharedPreferences

### 7. Persist the review list across app restarts ✅ DONE (2026-08-14)
New `lib/services/review_cache_service.dart` (`ReviewCacheService`), mirrors
`ScanCacheService`'s temp-file-then-rename JSON pattern in a separate
`review_cache.json`. `AppStateProvider` now takes an injectable
`ReviewCacheService` and calls `save(photoGroups)` (fire-and-forget, tracked
via `@visibleForTesting debugLastReviewSave` for deterministic test
awaiting) from both `finishScan` and `removeDeletedPhotos`, so the saved
copy is always written on scan completion and kept in sync after every
delete. `PermissionScreen._navigateAfterPermissionGranted` loads the saved
list on the permission-granted path; if one exists it calls the new
`AppStateProvider.loadSavedReview` and routes straight to
`DuplicateReviewScreen`, otherwise falls through to `ScanProgressScreen` as
before. `SummaryBar`'s existing "Re-scan" button doubles as the "Full
rescan" escape hatch — a fresh scan's `finishScan` overwrites the saved
copy. An empty saved list (e.g. every group got deleted down to nothing)
is treated as "nothing to resume" (`load()` returns `null`), falling back
to a fresh scan rather than showing an empty resumed screen. Tests:
`test/review_cache_service_test.dart` (round-trip, overwrite, empty/no-op,
clear, corrupt file, wrong version, malformed-group dropping) +
`test/app_state_provider_test.dart`'s "review-cache persistence" group.
`flutter analyze` clean, `flutter test` passing (pre-existing unrelated
flake: `similarity_service_test.dart`'s `clusterByTime clusters photos
within time window`, confirmed failing on a clean `main` checkout too, not
caused by this change).

### 8. Slider Compare, Blurry Detector, Large-File Finder, Album Scoping ✅ DONE (2026-08-14, merged to main 2026-08-15)
Implemented in isolated worktree `backlog8-advanced-features` (branch
`worktree-backlog8-advanced-features`), merged to `main` via `--no-ff` merge
commit. Plan: `.claude/plans/drifting-scribbling-token.md`.
- **Slider review UI**: `lib/screens/photo_slider_compare_screen.dart` —
  drag-divider overlap compare of any 2 photos, staged via long-press on
  two thumbnails in `PhotoGroupCard` (its `onLongPress` was unused before
  this). Free 2-of-N picker, not restricted to exactly-2-photo groups.
- **Album scoping** (generalizes "WhatsApp media scoping"):
  `PhotoScannerService.getAlbumList()` + optional `album` param on
  `scanAllPhotos`; picker shown on `ScanProgressScreen`'s ready-to-scan
  card, duplicates mode only. WhatsApp Images/Video just show up as
  ordinary albums — no WhatsApp-specific code needed.
- **New home/menu screen** (`lib/screens/home_screen.dart`): fork point for
  the 3 scan modes (`lib/models/scan_mode.dart`'s `ScanMode` enum).
  `PermissionScreen` now routes here instead of straight into the dupe
  scan; `ScanProgressScreen` takes a required `mode` param and dispatches
  to `_runDuplicateScan`/`_runBlurScan`/`_runLargeFileScan`.
- **Blurry photo detector**: `lib/services/blur_scan_service.dart`, reuses
  `ScoringService.computeSharpness` (already correct/tested) across every
  photo (not just time-cluster candidates), threshold 0.15. Deliberately
  NO checkpoint/resume cache (scope trim vs. the plan's original
  `blur_cache_service.dart` — a single full pass was judged not worth the
  added dual-resume-UI complexity; `isCancelled` still works via the
  shared `ScanCancelledException`).
- **Large-file finder**: `lib/services/large_file_scan_service.dart`,
  scoped to the photo/video library (`RequestType.common`, metadata-only,
  10MB floor, top 100 results) — NOT a general filesystem scan, avoiding
  `MANAGE_EXTERNAL_STORAGE` (see Constraints below). Needed
  `READ_MEDIA_VIDEO` added to the manifest + `Permission.videos` requested
  alongside `Permission.photos`.
- **Shared review UI**: blurry/large-file results are flat,
  independently-flagged lists (no "best photo" comparison), so they share
  `lib/screens/flagged_photo_review_screen.dart` +
  `lib/widgets/flagged_photo_list.dart` rather than reusing
  `PhotoGroupCard`/`SummaryBar` (those are shaped around `PhotoGroup`).
- **Cut**: general cache/junk cleaner — no public Android API to clear
  another app's cache without `MANAGE_EXTERNAL_STORAGE` + the file-manager
  role, which Play Store restricts to actual file-manager apps.
- **Cut**: re-scan-as-merge — user judged the existing full-rescan button
  sufficient as-is.
- `flutter analyze` clean, `flutter test` 117/118 passing (same
  pre-existing `clusterByTime` flake noted in item 7, unrelated to this
  work). New test: `test/photo_slider_compare_screen_test.dart`.
- **Not yet done**: Settings-screen wiring for the blur threshold. On-device
  testing (Samsung SM-G990E) done -- see item 10 for what it found.
- iOS support remains untested/out of scope (see Constraints below).
- **Bug found + fixed during on-device testing (2026-08-15)**:
  `PhotoScannerService`'s Phase 1 metadata fetch runs 16 concurrent futures
  per chunk and inserts into a `Map` in completion order (non-deterministic
  I/O timing), then sorts by `createDateTime` — but `List.sort` isn't
  stable, so photos sharing an exact timestamp (burst shots, batch
  imports/saves — exactly the ones most likely to be duplicates) could sort
  relative to each other differently between runs of the SAME library,
  making "Scan All Photos" non-reproducible run to run. Fixed via
  `comparePhotosByTimeThenId` (tie-break by `id`), regression test in
  `test/photo_scanner_service_test.dart`.
- **Still open**: after the above fix, re-scanning the SAME library
  consistently gives the SAME group count -- confirmed on-device, matches
  the count from a pristine baseline build of `main` (commit `1044541`) too
  -- but an earlier (pre-fix, non-deterministic) run had shown a much
  higher count (~75 vs. the now-stable ~35) on the same library. Root
  cause traced to `SimilarityService.groupBySimilarity`
  (`lib/services/similarity_service.dart`): it's a greedy, anchor-based
  grouper -- the first not-yet-used photo in list order becomes the
  "anchor," and only photos within the Hamming threshold OF THAT ANCHOR
  join its group (not of each other) -- so for a "chain" of similar photos
  (A~B and B~C both match, but A~C doesn't), the result depends on which
  one happens to be the anchor. This is a real, pre-existing, order-
  dependent design property, not something introduced this session --
  user asked whether to change it to an order-independent transitive/
  connected-components grouping (would likely be more inclusive and, more
  importantly, stop depending on list order at all) -- **decision still
  pending**, do not implement without an explicit go-ahead.

### 9. Show group count in the Review screen header ✅ DONE (2026-08-15)
`DuplicateReviewScreen`'s AppBar title now reads "Review Duplicates (XX
groups)" (singular "group" for XX=1, plain "Review Duplicates" for
XX=0 -- the empty state already says "No duplicates found" there, a count
would be redundant). Switched the screen from a body-scoped `Consumer` to
`context.watch<AppStateProvider>()` at the top of `build()` so the AppBar
title -- not just the body -- rebuilds when `photoGroups` changes; a
`Consumer` wrapping only the body never would have reached the title.
Live-updates through the existing `AppStateProvider.removeDeletedPhotos` ->
`notifyListeners()` path, no new state needed. Later renamed to "Review
Dupes (XX groups)" per user request (2026-08-15).

### 10. On-device UX fixes from testing rounds ✅ DONE (2026-08-15)
Found/requested while testing item 8 on a real device (Samsung SM-G990E),
all in the same merged branch:
- Fullscreen viewer: `PageView` swipe-to-next-photo was stealing the
  gesture arena from `InteractiveViewer`'s pinch-to-zoom. Fixed with a
  `Listener`-tracked pointer count (paging fully disabled once a 2nd finger
  is down) + a custom `PageScrollPhysics` with a higher
  `dragStartDistanceMotionThreshold` for single-finger swipes.
- Slider compare screen gained zoom (+/- buttons in the AppBar, 1x-4x) and
  pan (arrows on the 4 screen edges, shown only while zoomed) -- both
  apply identically to both photo layers (`Transform.scale`/`.translate`
  with the same `scale`/`pan` values) so they stay aligned; buttons rather
  than pinch/drag gestures, which would have fought the divider's own drag
  gesture in the same view. Pan is clamped to how far the zoomed content
  actually extends past the viewport.
- Album picker: `DropdownButtonFormField` was missing `isExpanded: true`,
  so long album names overflowed (Flutter's debug "RIGHT OVERFLOWED BY N
  PIXELS" banner) instead of the existing `TextOverflow.ellipsis` kicking
  in.
- Scan progress label showed the PREVIOUS scan's stale "X/X" numbers until
  the new scan's first progress callback fired -- `AppStateProvider.
  startScan()` now clears `scanStatus` to `null` so it falls back to the
  generic "Scanning..." label instead.
- `PhotoGroupCard`'s expanded/collapsed state was getting lost on fast
  scrolling (ListView.builder disposes off-screen State beyond the cache
  extent). Fixed via `AutomaticKeepAliveClientMixin` with `wantKeepAlive =>
  _isExpanded` (only pins alive the cards actually expanded).
- After a delete collapses a group to 0-1 photos, the review screen now
  auto-scrolls (not just auto-expands, which already existed) to the
  neighbor group via a per-group `GlobalKey` + `Scrollable.ensureVisible`.
- Compare pair-staging changed from long-press to a checkbox in each
  thumbnail's bottom-right corner (checking a 2nd photo immediately opens
  the compare screen); left/right in the compare screen is now assigned by
  the photos' position within the group, not tap order.
- Fixed the slider's visual direction: dragging the divider right now
  reveals more of the LEFT photo (was backwards -- the clipped/base layer
  roles in the `Stack` were swapped from what the divider position implied).

## Backlog: Remote Netbook Dedup (python-mvp1 extension, not the Flutter app)

### 1. Run dupesweep against photos backed up on the old netbook (192.168.4.36)
An i386 Atom N270 / 2GB RAM netbook (Python 3.6.9 only) holds a folder of
backed-up phone photos and is reachable via SSH. It's too weak to do
hashing/scoring/thumbnailing itself.
- **Decided (2026-08-14)**: Transport is **SSH/SFTP only** — no server on the
  netbook. A PC-side Python script uses `paramiko` (SFTP) to list files and
  pull raw bytes for hashing/scoring/thumbnailing (reusing `python-mvp1`'s
  `cluster_by_time`/`split_by_similarity`/scoring logic, run on the PC where
  it's fast). Deletion moves files into a `_to_delete` folder on the netbook
  via an SSH exec call (never hard-delete — same guarantee as
  `apply_delete_list.py`), not a hard delete.
- **Key UX change from python-mvp1**: the reviewer HTML must call delete
  directly (fetch → local server → SSH → netbook) when a photo is marked,
  not export a CSV for a separate `apply_delete_list.py` run later. Needs a
  small local Flask/HTTP server on the PC (not the netbook) that the HTML's
  JS calls at `localhost`; that server does the actual paramiko SFTP/SSH
  work. Must be running while reviewing.
- **Open before implementing**: netbook's backed-up-photos folder path, SSH
  auth (key vs password — set up a key if not already), and whether this
  lives in a new sibling folder (e.g. `python-mvp2/` or `remote-netbook/`)
  or extends `python-mvp1/` in place.
- **Effort**: Medium — mostly plumbing (paramiko SFTP wrapper + local Flask
  app + reused clustering/scoring/HTML-template code); algorithm itself is
  already validated in `python-mvp1`.

### 2. Archive-move mode: sync_data → archive on the netbook (frees phone storage)
Netbook paths: `/media/backup/sync_data` (live sync target from phone) →
`/media/backup/archive` (stable, not touched by the sync tool). Moving
photos out of the actively-synced tree before deleting them from the phone
protects the archived copy from a two-way sync tool cleaning it up — same
class of risk already flagged in `python-mvp1/README_MVP1.md`'s "Known
constraint learned the hard way".
- **Decided (2026-08-14)**: same-disk `sftp.rename` (netbook→netbook, no
  bytes cross the network — near-instant even on the weak Atom). New mode
  in `serve_review.py` (not a separate script) — reuses the `/browse`
  folder picker to choose a `sync_data` subfolder, adds an optional
  date-range filter (by file mtime, no EXIF parsing needed, keeps this
  feature Pillow-free), skips anything modified in the last few minutes
  (mid-sync guard), preserves subfolder structure under `archive/`.
- **Depends on**: `remote_client.py`/`serve_review.py` from
  `.claude/plans/remote-netbook-dedup.md` (not yet built). Full plan:
  `.claude/plans/archive-remote-photos.md`.
- **Effort**: Low-Medium — mostly a recursive same-disk move + folder-picker
  UI reuse; no hashing/scoring/thumbnailing involved at all.

## Release & Play Store Publication

### Prepare App for Play Store Publication
Backlog item to prepare DupeSweep for public release on Google Play Store.
- **Scope**: TBD (app signing, privacy policy, screenshots, release notes, version management, testing on multiple devices)
- **Status**: Not started
- **Effort**: TBD — requires app signing setup, Play Store account, metadata preparation

## Constraints & Gotchas

**No Cloud**: This is a personal tool. Never add analytics, telemetry, or cloud sync.
**Explicit Deletion**: Every delete requires user confirmation + OS dialog. No silent deletes.
**Android First**: iOS support is aspirational but untested. Do not spend time on it yet.
**Scoped Storage**: A general any-file large-file/junk finder needs MANAGE_EXTERNAL_STORAGE (Play-Store-incompatible, file-manager-role only). The implemented large-file finder (2026-08-14, item 8) is scoped to the photo/video library instead, avoiding that permission — a general filesystem version and the cache/junk cleaner both remain cut for this reason.

## Git & Commits

Commit style: "Title + 1-2 lines, no trailers"
Never auto-commit. Wait for user command before committing.
