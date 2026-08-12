#!/usr/bin/env python3
"""
find_duplicate_photos.py

Finds near-duplicate / burst photos in a folder (e.g. a synced phone camera
folder), groups them by time proximity + visual similarity, scores each
photo in a group for sharpness/exposure, and writes a report suggesting
which one to keep and which to delete.

It NEVER deletes anything itself. It only writes a report (Markdown + CSV)
for you to review. Use --delete-suggested only after you've read the report,
and it moves files to a "_to_delete" subfolder instead of hard-deleting them,
so you can still recover them.

Usage:
    python3 find_duplicate_photos.py /path/to/Camera
    python3 find_duplicate_photos.py /path/to/Camera --time-window 120 --hash-distance 10
    python3 find_duplicate_photos.py /path/to/Camera --delete-suggested

Dependencies: pillow, imagehash, numpy (pip install pillow imagehash numpy)
"""

import argparse
import csv
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from PIL import Image, ExifTags
import imagehash
import numpy as np

IMAGE_EXTS = {".jpg", ".jpeg", ".png"}
EXCLUDE_PREFIXES = (".trashed-", ".temp-", ".pending-")

EXIF_IFD_TAG = 0x8769  # pointer to the Exif sub-IFD, where DateTimeOriginal actually lives
DATETIME_ORIGINAL_TAG = 36867
DATETIME_TOPLEVEL_TAG = 306  # "DateTime" (modify date) on IFD0, fallback only


def list_images(folder: Path):
    for root, _dirs, files in os.walk(folder):
        for name in files:
            if name.startswith(EXCLUDE_PREFIXES):
                continue
            ext = Path(name).suffix.lower()
            if ext in IMAGE_EXTS:
                yield Path(root) / name


def hash_and_timestamp(path: Path):
    """Single file open that gets both the EXIF timestamp and the perceptual
    hash, using JPEG draft mode so libjpeg decodes at a reduced DCT scale
    instead of full resolution — this is the single biggest speedup for
    scanning thousands of 10+ MP phone photos."""
    ts = None
    phash = None
    try:
        with Image.open(path) as img:
            exif = img.getexif()
            if exif:
                try:
                    exif_ifd = exif.get_ifd(EXIF_IFD_TAG)
                except Exception:
                    exif_ifd = {}
                raw = exif_ifd.get(DATETIME_ORIGINAL_TAG) or exif.get(DATETIME_TOPLEVEL_TAG)
                if raw:
                    try:
                        ts = datetime.strptime(raw, "%Y:%m:%d %H:%M:%S")
                    except Exception:
                        ts = None
            # draft() only helps JPEGs and only reduces decode scale, never
            # increases it beyond the source size, so it's always safe to call
            img.draft("L", (64, 64))
            phash = imagehash.phash(img)
    except Exception:
        pass
    if ts is None:
        ts = datetime.fromtimestamp(path.stat().st_mtime)
    return ts, phash


def _load_gray(path: Path, size: int):
    with Image.open(path) as img:
        img.draft("L", (size, size))
        return np.asarray(img.convert("L").resize((size, size)), dtype=np.float64)


def score_photo(path: Path):
    """Sharpness + exposure penalty from a single file open (used to cost
    two separate Image.open calls per photo — halved here since each open
    against a slow mount is the expensive part, not the math)."""
    try:
        gray = _load_gray(path, 512)
        lap = (
            -4 * gray[1:-1, 1:-1]
            + gray[:-2, 1:-1]
            + gray[2:, 1:-1]
            + gray[1:-1, :-2]
            + gray[1:-1, 2:]
        )
        sharpness = float(lap.var())

        mean = gray.mean()
        if mean < 40:
            exposure = (40 - mean) * 2
        elif mean > 220:
            exposure = (mean - 220) * 2
        else:
            exposure = 0.0
        return sharpness, float(exposure)
    except Exception:
        return 0.0, 0.0


def cluster_by_time(items, window_seconds: int):
    items = sorted(items, key=lambda x: x["ts"])
    clusters = []
    current = []
    for item in items:
        if current and (item["ts"] - current[-1]["ts"]).total_seconds() > window_seconds:
            clusters.append(current)
            current = []
        current.append(item)
    if current:
        clusters.append(current)
    return [c for c in clusters if len(c) > 1]


def split_by_similarity(cluster, hash_distance: int):
    """Within a time cluster, group items whose phash is close enough
    (union-find style greedy grouping) so unrelated photos taken seconds
    apart don't get lumped together."""
    groups = []
    for item in cluster:
        placed = False
        if item["hash"] is None:
            groups.append([item])
            continue
        for g in groups:
            rep = g[0]
            if rep["hash"] is not None and (item["hash"] - rep["hash"]) <= hash_distance:
                g.append(item)
                placed = True
                break
        if not placed:
            groups.append([item])
    return [g for g in groups if len(g) > 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("folder", type=str, help="Folder to scan (recursive)")
    ap.add_argument("--time-window", type=int, default=120,
                     help="Seconds between shots to consider them the same burst (default 120)")
    ap.add_argument("--hash-distance", type=int, default=10,
                     help="Max perceptual-hash Hamming distance to count as visually similar, 0-64 (default 10)")
    ap.add_argument("--out-dir", type=str, default=None,
                     help="Where to write the report (default: same as this script)")
    ap.add_argument("--delete-suggested", action="store_true",
                     help="Move (not delete) all non-best photos in each group into a _to_delete folder")
    ap.add_argument("--cache-file", type=str, default=None,
                     help="Path to a JSON cache of already-hashed files, so re-runs skip work "
                          "already done (default: <out-dir>/hash_cache.json)")
    ap.add_argument("--max-seconds", type=float, default=None,
                     help="Stop hashing (and save progress to the cache) after this many seconds. "
                          "Re-run the same command to resume. Omit to run to completion.")
    ap.add_argument("--workers", type=int, default=16,
                     help="Thread pool size for hashing (I/O-bound work, default 16)")
    args = ap.parse_args()

    folder = Path(args.folder)
    if not folder.exists():
        print(f"Folder not found: {folder}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.out_dir) if args.out_dir else Path(__file__).resolve().parent
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_path = Path(args.cache_file) if args.cache_file else out_dir / "hash_cache.json"

    print(f"Scanning {folder} ...")
    paths = list(list_images(folder))
    print(f"Found {len(paths)} image files (excluding trashed/temp).")

    cache = {}
    if cache_path.exists():
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                cache = json.load(f)
        except Exception:
            cache = {}

    missing = [p for p in paths if str(p) not in cache]
    print(f"{len(paths) - len(missing)} already hashed (cached), {len(missing)} remaining.")

    start = time.monotonic()
    processed_this_run = 0
    # I/O-bound (waiting on the mounted folder), not CPU-bound, so threads
    # give a near-linear speedup here even under the GIL.
    executor = ThreadPoolExecutor(max_workers=args.workers)
    futures = {executor.submit(hash_and_timestamp, p): p for p in missing}
    try:
        for fut in as_completed(futures):
            p = futures[fut]
            try:
                ts, phash = fut.result()
            except Exception:
                ts, phash = datetime.fromtimestamp(p.stat().st_mtime), None
            cache[str(p)] = {
                "ts": ts.isoformat(),
                "hash": str(phash) if phash is not None else None,
                "size": p.stat().st_size,
            }
            processed_this_run += 1
            if processed_this_run % 100 == 0:
                print(f"  hashed {processed_this_run}/{len(missing)} this run "
                      f"({time.monotonic() - start:.0f}s elapsed)")
                with open(cache_path, "w", encoding="utf-8") as f:
                    json.dump(cache, f)
            if args.max_seconds is not None and (time.monotonic() - start) > args.max_seconds:
                break
    finally:
        executor.shutdown(wait=False, cancel_futures=True)

    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f)
    print(f"Hashed {processed_this_run} files this run. Cache: {cache_path} "
          f"({len(cache)}/{len(paths)} total files cached).")

    still_missing = [p for p in paths if str(p) not in cache]
    if still_missing:
        print(f"\n{len(still_missing)} files still not hashed. Re-run the same command "
              f"to continue (progress is saved in the cache file).")
        sys.stdout.flush()
        # Cache is already durably written above. Some worker threads may
        # still be blocked on slow I/O against the mounted folder — os._exit
        # skips Python's normal interpreter shutdown (which would otherwise
        # join those threads and could hang well past --max-seconds).
        os._exit(2)

    items = []
    for p in paths:
        entry = cache[str(p)]
        items.append({
            "path": p,
            "ts": datetime.fromisoformat(entry["ts"]),
            "hash": imagehash.hex_to_hash(entry["hash"]) if entry["hash"] else None,
            "size": entry["size"],
        })

    time_clusters = cluster_by_time(items, args.time_window)
    print(f"Time-proximity clusters (>=2 photos within {args.time_window}s): {len(time_clusters)}")

    all_groups = []
    for tc in time_clusters:
        all_groups.extend(split_by_similarity(tc, args.hash_distance))
    print(f"Visually-similar groups after phash filtering: {len(all_groups)}")

    # Scoring needs another file open per item (for sharpness/exposure), so
    # it gets the same threaded + resumable treatment as hashing above —
    # this is what was missing before and caused the timeout on a "final"
    # run that still had ~770 unscored photos left to open.
    score_cache_path = out_dir / "score_cache.json"
    score_cache = {}
    if score_cache_path.exists():
        try:
            with open(score_cache_path, "r", encoding="utf-8") as f:
                score_cache = json.load(f)
        except Exception:
            score_cache = {}

    to_score_paths = sorted({str(item["path"]) for g in all_groups for item in g})
    missing_scores = [p for p in to_score_paths if p not in score_cache]
    print(f"{len(to_score_paths) - len(missing_scores)}/{len(to_score_paths)} group photos "
          f"already scored (cached), {len(missing_scores)} remaining.")

    if missing_scores:
        score_start = time.monotonic()
        scored_this_run = 0
        executor = ThreadPoolExecutor(max_workers=args.workers)
        futures = {executor.submit(score_photo, Path(p)): p for p in missing_scores}
        try:
            for fut in as_completed(futures):
                p = futures[fut]
                try:
                    sharpness, exposure = fut.result()
                except Exception:
                    sharpness, exposure = 0.0, 0.0
                score_cache[p] = {"sharpness": sharpness, "exposure_penalty": exposure}
                scored_this_run += 1
                if scored_this_run % 100 == 0:
                    print(f"  scored {scored_this_run}/{len(missing_scores)} this run "
                          f"({time.monotonic() - score_start:.0f}s elapsed)")
                    with open(score_cache_path, "w", encoding="utf-8") as f:
                        json.dump(score_cache, f)
                if args.max_seconds is not None and (time.monotonic() - score_start) > args.max_seconds:
                    break
        finally:
            executor.shutdown(wait=False, cancel_futures=True)

        with open(score_cache_path, "w", encoding="utf-8") as f:
            json.dump(score_cache, f)
        print(f"Scored {scored_this_run} files this run "
              f"({len(score_cache)}/{len(to_score_paths)} total scored).")

        still_missing_scores = [p for p in to_score_paths if p not in score_cache]
        if still_missing_scores:
            print(f"\n{len(still_missing_scores)} group photos still not scored. "
                  f"Re-run the same command to continue (progress is saved).")
            sys.stdout.flush()
            os._exit(2)

    for g in all_groups:
        for item in g:
            s = score_cache[str(item["path"])]
            item["sharpness"] = s["sharpness"]
            item["exposure_penalty"] = s["exposure_penalty"]
            item["score"] = item["sharpness"] - item["exposure_penalty"]
        g.sort(key=lambda x: x["score"], reverse=True)

    total_reclaim = sum(
        item["size"] for g in all_groups for item in g[1:]
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    md_path = out_dir / "duplicate_report.md"
    csv_path = out_dir / "duplicate_report.csv"

    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# Duplicate / burst photo report\n\n")
        f.write(f"Scanned: `{folder}`\n\n")
        f.write(f"Groups found: {len(all_groups)}\n\n")
        f.write(f"Space reclaimable if you delete all non-best photos: "
                f"{total_reclaim / (1024*1024):.1f} MB\n\n")
        for idx, g in enumerate(all_groups, 1):
            f.write(f"## Group {idx} ({g[0]['ts'].strftime('%Y-%m-%d %H:%M:%S')}, {len(g)} photos)\n\n")
            for rank, item in enumerate(g):
                tag = "KEEP (best)" if rank == 0 else "suggest delete"
                f.write(f"- [{tag}] `{item['path']}` "
                        f"(score={item['score']:.1f}, {item['size']/1024:.0f} KB, {item['ts']})\n")
            f.write("\n")

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["group", "rank", "decision", "path", "score", "size_kb", "timestamp"])
        for idx, g in enumerate(all_groups, 1):
            for rank, item in enumerate(g):
                decision = "keep" if rank == 0 else "delete_suggested"
                w.writerow([idx, rank, decision, str(item["path"]),
                            f"{item['score']:.1f}", f"{item['size']/1024:.0f}",
                            item["ts"].isoformat()])

    print(f"\nReport written to:\n  {md_path}\n  {csv_path}")

    if args.delete_suggested:
        trash_dir = folder / "_to_delete"
        trash_dir.mkdir(exist_ok=True)
        moved = 0
        for g in all_groups:
            for item in g[1:]:
                dest = trash_dir / item["path"].name
                item["path"].rename(dest)
                moved += 1
        print(f"Moved {moved} files into {trash_dir} (not permanently deleted).")


if __name__ == "__main__":
    main()
