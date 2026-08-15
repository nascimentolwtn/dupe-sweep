# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**DupeSweep** is a lightweight Flutter/Dart Android app for finding and reviewing duplicate photos on a device. It uses time-based clustering and perceptual hashing (dHash) to group similar photos, with manual selection + OS confirmation for deletion. Personal use only—no analytics, ads, or cloud sync.

Key principle: **No auto-delete**. Every deletion requires explicit user selection and OS confirmation by design.

## Build, Run & Test

### Build and Run
```bash
# Install dependencies
flutter pub get

# Run on connected device or emulator
flutter run

# Run with verbose output for debugging
flutter run -v
```

### Testing
```bash
# Run all unit tests
flutter test

# Run a specific test file
flutter test test/similarity_service_test.dart

# Run tests with coverage
flutter test --coverage
```

Current tests cover:
- Time-based clustering with various time windows
- Hamming distance calculations
- Perceptual hash grouping logic

### Linting and Analysis
```bash
# Run static analyzer
flutter analyze

# Format code
dart format lib/ test/
```

### Daily Development Commands
```bash
# Check connected devices
flutter devices

# View app logs in real-time
flutter logs

# Troubleshoot environment setup
flutter doctor

# Restart ADB (if device connection issues)
adb kill-server
adb start-server
```

## Architecture

### State Management
**Provider pattern** (via `provider` package) with a single `AppStateProvider` in `main.dart`:
- `photoGroups`: List of grouped photos
- `isScanning`: Boolean scan state
- `scanProgress`: 0.0–1.0 progress value
- `scanStatus`: Human-readable status string

Navigation flows through three screens (permission → scan progress → review).

### Core Models
- **PhotoItem** (`lib/models/photo_item.dart`): Single photo metadata (id, path, creation date, file size, selection state, best-photo flag)
- **PhotoGroup** (`lib/models/photo_group.dart`): Group of photos with helper methods (`selectAllNonBest()`, `reclaimableBytes`, etc.)

### Services Layer
Four service classes handle distinct responsibilities:

1. **PhotoScannerService** (`lib/services/photo_scanner_service.dart`)
   - Reads all photos from device via `photo_manager` package
   - Runs in isolate (`compute()`) to prevent UI freezing
   - Returns sorted `PhotoItem` list

2. **SimilarityService** (`lib/services/similarity_service.dart`)
   - Time-based clustering: groups photos within `timeWindowSeconds` (default 120s)
   - Perceptual hashing (dHash): computes 64-bit difference hash from image bytes
   - Hamming distance calculation for hash similarity
   - **Status**: Clustering implemented; hash-based sub-grouping computed but not yet integrated into review UI

3. **ScoringService** (`lib/services/scoring_service.dart`)
   - Sharpness scoring: Laplacian-based focus detection
   - Exposure scoring: histogram-based brightness analysis
   - Flags "best" photo in each group
   - **Status**: Computed but not yet auto-selecting "best" in review UI

4. **DeletionService** (`lib/services/deletion_service.dart`)
   - Wraps `photo_manager` delete calls
   - Triggers Android system delete confirmation dialog

### UI/Screens
- **PermissionScreen**: Request photo library permission
- **ScanProgressScreen**: Show real-time scan progress with status updates
- **DuplicateReviewScreen**: Main review UI—display grouped photos, select for deletion, confirm

### Widgets & Utils
- **PhotoGroupCard**: Expandable card per group (expandable to show all photos in that group)
- **SummaryBar**: Bottom action bar (select/deselect all, delete confirmation)
- **ByteFormatter**: Utility to format bytes as KB/MB/GB

## Key Technical Details

### Threading & Performance
- **Isolates**: Photo scanning runs in a Dart isolate via `compute()` to keep UI responsive on large libraries
- **Thumbnails**: Scanning uses 200×200 thumbnails, not full-resolution images
- **Lazy Loading**: Implement lazy thumbnail loading if review screen becomes slow

### Dependencies
- `flutter`: SDK framework
- `provider`: ^6.0.0 – State management
- `photo_manager`: ^2.7.0 – Gallery access, thumbnails, delete operations
- `permission_handler`: ^11.4.0 – Runtime permission requests
- `image`: ^4.0.0 – Pixel-level operations (dHash, scoring)
- `flutter_lints`: ^2.0.0 – Linting rules

### Android & Permissions
- **Target SDK**: API 33+
- **Permissions**: Photo library access (requested at runtime)
- **AndroidManifest.xml**: Located at `android/app/src/main/AndroidManifest.xml`

## Roadmap Status

### ✅ Implemented
- Permission flow
- Photo scanning (off UI thread via isolates)
- Group photos by date
- Display thumbnails
- Manual selection + OS confirmation delete flow
- Unit tests for clustering/hashing logic

### 🚧 In Progress / Planned
- **Perceptual hashing integration**: dHash computed but not used in grouping UI yet
- **Sharpness + exposure scoring**: Computed but "best" photo not auto-selected in review
- **UI polish**: Better styling, dark mode, animations
- **Performance tuning**: Batch operations, optimize thumbnail loading
- **Settings screen**: Configurable time window, Hamming distance threshold
- **Advanced grouping**: Toggle between time-based and hash-based sub-grouping
- **Re-scan flow**: Re-run scan and merge with previous results
- **iOS support**: Structure left open but untested

## Common Patterns & Conventions

### File Organization
Flat namespace per tier (models/, services/, screens/, widgets/, utils/). Keep related classes in single files unless they exceed ~300 lines.

### Async Operations
Use `async`/`await` for future-based calls; wrap long operations in `compute()` to offload to isolate.

### Error Handling
- Permission checks before accessing photos
- Graceful degradation if a photo fails to hash or score
- Log errors; don't crash the UI

### Testing
Test-specific logic lives in `test/`. Focus on algorithm correctness (clustering, hashing) rather than UI tests initially. Use `flutter test` for all Dart tests.

## Sibling Python Tools (Not the Flutter App)

Two Python prototypes live alongside the Flutter app under `python/`, but
are not part of its build (`flutter build`/`flutter run` never touch them —
not under `assets/`, not in `pubspec.yaml`):

### `python/mvp1/`
The original validated dedup pipeline against a **local folder** — built
and run against a real ~3,900-photo library before the clustering/hashing/
scoring logic was ported into `lib/services/similarity_service.dart` and
`scoring_service.dart`. Kept as the local-folder reference; if the
algorithm changes here, mirror it there (or note the divergence).
- `find_duplicate_photos.py` — scans, time-clusters, phash-subgroups,
  sharpness/exposure-scores, writes a Markdown + CSV report. Threaded,
  resumable via `hash_cache.json`/`score_cache.json`.
- `build_review_html.py` — builds a self-contained HTML review page with
  embedded thumbnails and a `file://` lightbox.
- `apply_delete_list.py` — moves files listed in the exported CSV into a
  sibling `_to_delete` folder. Never hard-deletes.
- Run: `pip install pillow imagehash numpy`, then
  `python3 find_duplicate_photos.py <folder> --out-dir ./run`,
  `python3 build_review_html.py --out-dir ./run`,
  `python3 apply_delete_list.py ./run/delete_list.csv`.

### `python/mvp2-remote/`
Same pipeline pointed at a folder on a **network-reachable machine**
(originally a backup netbook) over SSH/SFTP (`paramiko`), with delete
triggered directly from the browser instead of a CSV export. All heavy
image work (hashing, scoring, thumbnailing) runs on this PC, not the
remote machine — no server or new dependency is installed there, just the
`sshd` it's already reachable through.
- `remote_client.py` — SSH/SFTP connect, recursive remote walk
  (`list_images`), folder-picker listing (`list_subdirs`), prefetched
  bulk reads (`read_bytes`), move-to-`_to_delete` with collision handling
  (`move_to_trash`).
- `scan_remote.py` — staged, threaded, resumable hash → cluster → score →
  thumbnail pipeline (`run_scan()`, importable). CLI power-user shortcut:
  `python3 scan_remote.py <remote-folder> --host 192.168.4.36 --out-dir ./run`.
- `serve_review.py` — local Flask app, the single entry point
  (browse → scan → review → delete): `python3 serve_review.py --host 192.168.4.36 --out-dir ./run`,
  then open `http://127.0.0.1:5000/`.
- Setup: `pip install -r python/mvp2-remote/requirements.txt` (adds
  `paramiko`, `flask` on top of mvp1's deps). SSH key-based auth to the
  remote machine is a prerequisite, set up outside this code.
- Same **move-to-`_to_delete`, never hard-delete** guarantee as
  `apply_delete_list.py`. See `python/mvp2-remote/README_MVP2.md` for the
  full divergence notes and the sync-folder caution (don't stage deletes
  inside a folder under active two-way sync).

### Daily Usage

**mvp1 (local folder):**
```bash
cd python/mvp1
.venv\Scripts\activate          # or: source .venv/bin/activate on macOS/Linux

python3 find_duplicate_photos.py <folder> --out-dir ./run --max-seconds 30
# re-run the same command until it stops reporting "still not hashed/scored"

python3 build_review_html.py --out-dir ./run --max-seconds 30
# open run/duplicate_review.html in a browser, review, export delete_list.csv

python3 apply_delete_list.py run/delete_list.csv
```

**mvp2-remote (netbook over SSH, e.g. `192.168.4.36`):**
```bash
cd python/mvp2-remote
.venv\Scripts\activate          # or: source .venv/bin/activate on macOS/Linux

python3 serve_review.py --host 192.168.4.36 --out-dir ./run
# username, start-path, and key-filename all default (netbook / /media/backup /
# the WSL SSH key) -- override with --username/--start-path/--key-filename/
# --password if needed, or set DUPESWEEP_SSH_KEY to change the default key path
# open http://127.0.0.1:5000/ -- browse -> scan -> review -> delete
# (delete moves the file into _to_delete on the netbook, never hard-deletes)
```

## Important Constraints

1. **No Cloud**: This is a personal tool. Do not add cloud sync, analytics, or telemetry.
2. **Explicit Deletion**: Every delete requires user confirmation + OS dialog. No silent deletes.
3. **Android First**: iOS support is aspirational but not validated. Prioritize Android.
4. **Privacy**: Never log or transmit photo data, paths, or metadata beyond the device.

## Future Considerations

- When integrating hash-based grouping into the review UI, consider UX for sub-groups within time clusters.
- Scoring service currently marks "best" but the review screen should respect this flag.
- If thumbnail loading becomes slow, implement lazy/paginated loading or caching.
- Settings screen should expose time window and Hamming threshold as user-configurable values.
