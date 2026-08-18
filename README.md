# DupeSweep

**Version: 1.4.7**

A lightweight Android app for finding and reviewing duplicate photos on your phone. Your photo data is never uploaded or synced to the cloud. (Ads and a paid tier are planned — see the backlog.)

## Build & Run

### Prerequisites

- Flutter SDK (3.0+)
- Android SDK (API 33+)
- Connected Android device or emulator

### Steps

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Connect your Android device via USB (with debugging enabled) or start an emulator.

3. Run the app:
   ```bash
   flutter run
   ```

## How It Works

1. **Permission Request**: The app asks for photo library access. You must grant this permission to proceed.

2. **Photo Scan**: Reads all photos from your device via `photo_manager`. This runs off the UI thread to avoid freezing on large libraries.

3. **Grouping**: Photos are grouped by date (for this session). Future versions will add perceptual hashing to find visually similar photos within time clusters.

4. **Review**: For each group, you can select photos to delete. The "best" photo (determined by sharpness and exposure scoring) is marked—you can override this if you want.

5. **Delete**: Selected photos are deleted via the Android system dialog (you see the OS confirmation before anything is removed).

## Project Structure

```
lib/
  main.dart                      # App entry point, state management
  models/
    photo_item.dart              # Single photo + metadata
    photo_group.dart             # Group of photos + operations
  services/
    photo_scanner_service.dart   # Read photos from device
    similarity_service.dart      # Time clustering + dHash grouping
    scoring_service.dart         # Sharpness + exposure scoring
    deletion_service.dart        # Wrap photo_manager delete
  screens/
    permission_screen.dart       # Permission request UI
    scan_progress_screen.dart    # Show scan progress
    duplicate_review_screen.dart # Main review UI
  widgets/
    photo_group_card.dart        # Expandable card per group
    summary_bar.dart             # Bottom action bar
  utils/
    byte_formatter.dart          # Format bytes to KB/MB/GB
```

## Tech Stack

- **Flutter** (Dart) targeting Android 13+
- **provider**: Simple state management
- **photo_manager**: Gallery access, thumbnails, delete
- **permission_handler**: Runtime permission requests
- **image**: Pixel-level operations for hashing/scoring

## Roadmap

### Done
- ✅ Permission flow
- ✅ Photo scanning (off UI thread)
- ✅ Group photos by date
- ✅ Display thumbnails
- ✅ Basic delete flow (manual selection + OS confirmation)
- ✅ Unit tests for clustering/hashing logic

### Not Yet Done
- [ ] **Perceptual hashing** (dHash) integrated into review screen—currently computed but not used for grouping
- [ ] **Sharpness + exposure scoring** integrated into review—currently computed but "best" not auto-selected
- [ ] **UI polish**: Better styling, dark mode, animations
- [ ] **Performance tuning**: Optimize thumbnail loading, batch operations
- [ ] **Settings screen**: Configurable time window (default 120s), Hamming distance threshold
- [ ] **Advanced grouping**: Option to enable/disable hash-based sub-grouping within time clusters
- [ ] **Re-scan flow**: Ability to re-run the scan and merge with previous results
- [ ] **iOS support** (currently Android only, structure left open but not tested)

## Notes

- **No auto-delete**: Every deletion requires explicit user selection and OS confirmation. This is by design.
- **Thumbnails only**: Scanning uses small thumbnails (200x200) for speed, not full-res images.
- **Off-UI-thread**: Photo scanning uses `compute()` (Dart isolates) to prevent UI freeze on large libraries.
- **No cloud sync**: Your photo data (paths, thumbnails, metadata) never leaves your device. Ads and a paid tier are planned (see roadmap/backlog) but won't change this.

## Testing

Run unit tests:
```bash
flutter test
```

Current tests cover:
- Time-based clustering with various time windows
- Hamming distance calculations
- Perceptual hash grouping logic

## Remote/Netbook Dedup (Python prototype, not the Android app)

`python/mvp2-remote/` is a separate command-line/browser tool for
deduplicating photos that live on a *different* machine reachable over
SSH — for example an old backup box too weak to hash/score thousands of
photos itself. Point it at a folder on that machine, review duplicate
groups in a browser (thumbnails, sharpness/exposure scoring, "best" pick),
and delete straight from the page — the file is only ever moved into a
`_to_delete` folder, never hard-deleted.

It also has an **archive mode**, for when that machine's photo folder is a
live two-way sync target (e.g. Syncthing from the phone): it relocates a
chosen folder into a separate, sync-untouched archive folder first (same
disk, instant), so it's safe to delete the phone-side originals afterwards
without the sync tool racing the cleanup. And a **purge/restore mode**,
since deleting only ever moves a file into a `_to_delete` folder: purge
permanently removes those files (the one irreversible operation in the
tool), restore moves them back to where they were deleted from.

See `python/mvp2-remote/README_MVP2.md` for setup and usage, and
`python/mvp1/README_MVP1.md` for the original local-only variant this was
built from.

## License

Personal use only.
