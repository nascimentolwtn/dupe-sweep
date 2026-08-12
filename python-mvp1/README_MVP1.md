# python-mvp1

A working Python/HTML prototype of DupeSweep's core duplicate-detection
pipeline, built and validated against a real ~3,900-photo library before
porting the logic into the Flutter app (`lib/services/similarity_service.dart`,
`scoring_service.dart`). Kept here for reference, not shipped in the app.

**This folder is not part of the Flutter build.** It isn't under `assets/`
and isn't declared anywhere in `pubspec.yaml`, so `flutter build`/`flutter run`
never touch it. It's a sibling tool, not an app dependency.

## What's here

- `find_duplicate_photos.py` — scans a folder, clusters photos by EXIF
  timestamp proximity (default 120s), sub-groups by perceptual hash (pHash,
  Hamming distance ≤10 by default), scores each photo in a group by
  sharpness (Laplacian variance) and exposure, and writes a Markdown + CSV
  report. Threaded and resumable (caches to `hash_cache.json`/
  `score_cache.json`) since scanning thousands of files over a slow mount
  can take multiple passes.
- `build_review_html.py` — turns the cached scan results into a single
  self-contained HTML file with embedded thumbnails, checkboxes defaulting
  to the AI's keep/delete pick, a full-resolution lightbox (opens the real
  file via a `file://` link, doesn't embed a second full-size copy), a
  "reviewed" flag per group, and save/resume support (localStorage +
  exportable JSON) so review can happen across multiple sessions.
- `apply_delete_list.py` — takes the CSV exported from the HTML viewer and
  moves the selected files into a sibling `_to_delete` folder. Never
  hard-deletes.

## Why this exists

Validating the clustering/hashing/scoring algorithm against real data and a
real review workflow before writing Dart was faster than iterating inside
an emulator. The Dart implementation should match this behavior; if you
change the algorithm in one, mirror it in the other or note the divergence.

## Known constraint learned the hard way

If you point this at a folder that's under active two-way sync (Syncthing,
FreeFileSync, etc.), don't create any output/staging folders (like
`_to_delete`) inside the synced tree — the sync tool can (and did, once)
clean up folders it doesn't recognize as part of the mirror. Point
`--out-dir` and any delete-staging folder somewhere outside the synced root.

## Usage

```bash
pip install pillow imagehash numpy

python3 find_duplicate_photos.py /path/to/photos --out-dir ./run --max-seconds 30
# re-run the same command until it stops reporting "still not hashed/scored"

python3 build_review_html.py --out-dir ./run --max-seconds 30
# open run/duplicate_review.html in a browser, review, export delete_list.csv

python3 apply_delete_list.py run/delete_list.csv
```

Generated artifacts (`*.json` caches, `duplicate_report.*`,
`duplicate_review.html`, `delete_list.csv`) contain real file paths and
embedded photo thumbnails from whatever library you point this at — they're
git-ignored (see `.gitignore` in this folder) and should never be committed.
