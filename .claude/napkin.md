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

### 7. Persist the review list across app restarts (requested 2026-08-14)
Currently `AppStateProvider.photoGroups` is pure in-memory state -- closing
the app loses the built review list entirely, forcing a full re-scan next
launch even though nothing changed. `ScanCacheService`'s save-points only
cover an *in-progress* scan's hashing work, not the *finished* grouped
result.
- **Wanted flow**: after a scan completes (and after every delete, so the
  saved copy never goes stale/points at deleted photos), persist the
  current `photoGroups` (+ selection state) to disk. On next launch, if a
  saved list exists, offer to resume reviewing it directly -- skip
  scanning entirely -- with a "Full rescan" button always available for
  when the user wants a fresh scan instead.
- **Design notes for whoever picks this up**: reuse the `ScanCacheService`
  JSON-file pattern (temp-file-then-rename, version field) rather than
  inventing a second mechanism; needs to store `PhotoGroup.id`/`groupType`/
  timestamp plus each `PhotoItem`'s id/fileSize/dhash/isBest/isSelected --
  everything `buildPhotoGroups` doesn't need to be recomputed from scratch.
  Write on `finishScan` and on every `removeDeletedPhotos` call (both
  already funnel through `AppStateProvider`, so both are natural save
  points). `main.dart`'s entry point (`PermissionScreen` -> auto-navigate)
  would need a new fork: saved review list exists -> go straight to
  `DuplicateReviewScreen`; otherwise -> `ScanProgressScreen` as today.
- **Effort**: Medium -- mostly plumbing similar to the existing scan-cache
  save points, plus one new decision point in the permission->home routing.

### 8. Advanced Features (Phase 2+, Do Not Start Yet)
- Re-scan flow (merge with previous results) — NOTE: basic Re-scan button now
  exists (full rescan, not a merge) as of 2026-08-14
- WhatsApp media scoping
- Blurry photo detector
- Cache/junk cleaner
- Large-file finder
- iOS support (untested)

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

## Constraints & Gotchas

**No Cloud**: This is a personal tool. Never add analytics, telemetry, or cloud sync.
**Explicit Deletion**: Every delete requires user confirmation + OS dialog. No silent deletes.
**Android First**: iOS support is aspirational but untested. Do not spend time on it yet.
**Scoped Storage**: Large-file finder needs MANAGE_EXTERNAL_STORAGE permission (only viable for sideloaded apps, not Play Store).

## Git & Commits

Commit style: "Title + 1-2 lines, no trailers"
Never auto-commit. Wait for user command before committing.
