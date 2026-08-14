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

### 2. Fix grouping so it matches python-mvp1 behavior (real-device bug)
Android is not matching similar shots by near date-time the way `python-mvp1/find_duplicate_photos.py` does.
- **Root cause**: `ScanProgressScreen._groupPhotosByDay` (`lib/screens/scan_progress_screen.dart:69-96`) buckets photos by **calendar day** (midnight-to-midnight), not by a rolling time gap. Two photos 2 minutes apart at 23:59/00:01 land in different groups; a whole day's photos get hash-compared against each other regardless of how many hours apart they were taken. `python-mvp1` uses `cluster_by_time` (gap ≤120s between consecutive sorted shots, see `find_duplicate_photos.py:120-131`), and so does the existing (but unused) `SimilarityService.clusterByTime` (`lib/services/similarity_service.dart:11-34`) — it's just never called.
- **Also**: `scan_progress_screen.dart` has its own inline copy of hash-grouping (`_addHashGroups`, `_hammingDistance`) duplicating `SimilarityService.groupBySimilarity`/`hammingDistance` — two implementations that can silently drift.
- **Also**: Dart's dHash (gradient-based, `similarity_service.dart:38-66`) is a different algorithm from Python's `imagehash.phash` (DCT-based) — thresholds of "10" mean different things in each; not necessarily a bug to fix now, but worth noting if match quality is still off after the time-window fix.
- **Impact**: This is the core value prop of the app (finding bursts/duplicates) — currently broken relative to the validated reference implementation.
- **Effort**: Medium — replace `_groupPhotosByDay` with `SimilarityService.clusterByTime` + `groupBySimilarity`, delete the duplicate inline logic.

### 3. Scan takes ~20min for ~7k photos on Samsung S22FE (real-device bug)
- **Root cause**: `PhotoScannerService.scanAllPhotos` (`lib/services/photo_scanner_service.dart:50-76`) awaits `thumbnailDataWithSize` + `fileSize` + dHash **sequentially, one photo at a time**, on the main thread (isolate was removed in commit "Fix isolate blocker by running scan on main thread"). Each iteration is a platform-channel round trip; nothing overlaps.
- **Reference**: `python-mvp1` uses a `ThreadPoolExecutor(max_workers=16)` for the equivalent I/O-bound hash pass (`find_duplicate_photos.py:204-227`), which is the actual reason it's fast.
- **Impact**: Core scan flow is nearly unusable on a real ~7k-photo library.
- **Effort**: Medium — batch with `Future.wait` (chunks of N concurrent `thumbnailDataWithSize` calls) instead of one-by-one; re-investigate why the isolate approach broke (platform channel init) since isolate + batching together would be ideal, but batching alone on main thread is the minimum fix.

### 4. Scan save points / pause & resume (real-device follow-up to #3)
If scan speed can't be fully fixed, let the user pause and resume a scan instead of losing all progress on interruption (backgrounding, crash, accidental back-nav).
- **Reference**: `python-mvp1` persists `hash_cache.json` incrementally every 100 files and is fully resumable by re-running the same command (`find_duplicate_photos.py:189-243`) — same pattern applies here.
- **Impact**: At current ~20min scan times, any interruption currently means starting over from photo 0.
- **Effort**: Medium — persist `{asset.id: {dhash, createDateTime, fileSize}}` to local storage (e.g. `shared_preferences` or a simple JSON file) periodically during scan; on next launch, skip already-scanned asset IDs and offer "Resume scan (N/M done)" vs "Start over."
- **Depends on**: Should land after #3 (batching) so the save/resume checkpoint cadence is designed around the new scan loop shape, not the old sequential one.

### 5. Review screen is hard to scroll (real-device bug)
- **Root cause**: `DuplicateReviewScreen` (`lib/screens/duplicate_review_screen.dart:51-58`) wraps groups in a bare `ListView.builder` with no `Scrollbar`. With hundreds of groups from a 7k-photo library, there's no visible/draggable scroll handle — only inertial flick-scrolling.
- **Impact**: Makes review painful/slow on large libraries, compounds the performance complaint.
- **Effort**: Low — wrap in `Scrollbar(thumbVisibility: true, trackVisibility: true, interactive: true, child: ListView.builder(...))` so there's a touchable/draggable thumb on the right edge.

### 6. "Grant permission" screen reappears every app start (real-device bug)
- **Root cause**: `PermissionScreen._checkPermission` (`lib/screens/permission_screen.dart:21-26`) checks `Permission.photos.status` in `initState` but only updates local `_hasPermission` state — it never auto-navigates to `ScanProgressScreen` when permission is already granted. Since `main.dart:28` always sets `PermissionScreen` as `home`, the user sees the "Grant Photo Access" screen/button on every launch even when access was already granted previously.
- **Impact**: Adds a pointless extra tap on every single app open.
- **Effort**: Low — in `_checkPermission`, if `status.isGranted`, navigate to `ScanProgressScreen` immediately (mirroring the navigation already done in `_requestPermission`).

### 7. Scoring UI Integration
Auto-select "best" photo in each group based on sharpness + exposure scoring.
- **Impact**: Reduces manual selection burden for bursts
- **Status**: ScoringService computes scores but review screen ignores them
- **Effort**: Low—add `isBest` flag to PhotoItem, update UI to highlight/preselect, respect scoring in delete workflow

### 8. Settings Screen
Expose configurable time window (default 120s) and Hamming distance threshold (default 10).
- **Impact**: Lets power users fine-tune grouping behavior
- **Effort**: Medium—add new screen, wire to state management, persist to SharedPreferences

### 9. UI Polish (Lower Priority)
- Dark mode
- Better styling / Material 3 refinement
- Animations (card expand/collapse, delete confirmation)

### 10. Advanced Features (Phase 2+, Do Not Start Yet)
- Re-scan flow (merge with previous results)
- WhatsApp media scoping
- Blurry photo detector
- Cache/junk cleaner
- Large-file finder
- iOS support (untested)

## Constraints & Gotchas

**No Cloud**: This is a personal tool. Never add analytics, telemetry, or cloud sync.
**Explicit Deletion**: Every delete requires user confirmation + OS dialog. No silent deletes.
**Android First**: iOS support is aspirational but untested. Do not spend time on it yet.
**Scoped Storage**: Large-file finder needs MANAGE_EXTERNAL_STORAGE permission (only viable for sideloaded apps, not Play Store).

## Git & Commits

Commit style: "Title + 1-2 lines, no trailers"
Never auto-commit. Wait for user command before committing.
