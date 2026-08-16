#!/usr/bin/env python3
"""
scan_remote.py

Remote equivalent of python-mvp1/find_duplicate_photos.py + the thumbnailing
half of build_review_html.py, combined into one staged pipeline against a
folder on the netbook instead of a local folder.

All the heavy image work (hashing, scoring, thumbnailing) happens on this
PC, not the netbook — files are pulled over SFTP with .prefetch() and
handed to Pillow from memory. The netbook itself does nothing but serve
directory listings and file bytes over its existing sshd.

Usable both as a standalone CLI (power-user shortcut when the remote folder
path is already known) and as an importable module: run_scan() is what
serve_review.py's /browse -> /scan flow calls directly on a background
thread, passing a progress_cb so the status page can poll live progress
instead of shelling out to a subprocess.

Pipeline (staged, like python-mvp1, so scoring/thumbnailing only happens on
photos that actually end up in a duplicate group, not the whole library):
  1. Walk the remote folder, hash + EXIF-timestamp every image found
     (hash_cache.json) -- needed for all files since clustering depends on it.
  2. Cluster by time proximity, then split into visually-similar groups by
     perceptual hash Hamming distance.
  3. Score sharpness/exposure for photos in groups only (score_cache.json).
  4. Thumbnail photos in groups only (thumb_cache.json).

Every stage is threaded (I/O-bound) and resumable: progress is saved to its
cache file periodically, so a dropped connection or --max-seconds cutoff
just means re-running the same command to continue.

Concurrency caveat: keep --workers low (default 4). Each worker opens its
own SSHClient/SFTPClient (paramiko's SFTPClient isn't meant to be shared
across threads) -- and the netbook's single Atom core is the real ceiling
here regardless of PC-side thread count.

Sync-folder caution: per python-mvp1/README_MVP1.md's "Known constraint
learned the hard way", if the netbook's photo folder is under active sync
(Syncthing etc.), don't point serve_review.py's delete flow at creating
_to_delete inside that synced tree without checking first -- the sync tool
can clean up staging folders it doesn't recognize.

Usage:
    python3 scan_remote.py /media/backup/sync_data/Camera \\
        --host 192.168.4.36 --out-dir ./run --max-seconds 60
    (re-run the same command until it reports done)

Dependencies: pillow, imagehash, numpy, paramiko (pip install -r requirements.txt)
"""

import argparse
import base64
import functools
import io
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageOps
import imagehash
import numpy as np
import piexif

import remote_client

TIME_WINDOW = 120
HASH_DISTANCE = 10
THUMB_MAX_DIM = 280
THUMB_QUALITY = 60
SAVE_EVERY = 20  # cache-flush + progress-report cadence within a stage

# Most camera/phone JPEGs embed a small preview thumbnail (commonly ~160x120,
# a few KB) inside the EXIF APP1 marker, which the JPEG spec caps at 65533
# bytes -- and that marker sits near the very start of the file, before the
# multi-MB compressed image data. Reading just this prefix and hashing the
# embedded thumbnail instead of the full photo is what makes hashing fast
# over a weak netbook: see _hash_worker's comment for the full rationale.
HASH_PREFIX_BYTES = 200 * 1024

# The SSH key lives under the WSL filesystem on this machine, not the
# Windows user's own ~/.ssh (which paramiko searches by default when no
# --key-filename is given). Overridable via DUPESWEEP_SSH_KEY so this isn't
# baked in if the WSL distro/username ever changes.
DEFAULT_KEY_FILENAME = os.environ.get(
    "DUPESWEEP_SSH_KEY",
    r"\\wsl.localhost\Ubuntu\home\lw_na\.ssh\id_ed25519",
)

EXIF_IFD_TAG = 0x8769  # pointer to the Exif sub-IFD, where DateTimeOriginal actually lives
DATETIME_ORIGINAL_TAG = 36867
DATETIME_TOPLEVEL_TAG = 306  # "DateTime" (modify date) on IFD0, fallback only


class ConnectionPool:
    """One SSHClient/SFTPClient per worker thread, created lazily and reused
    across that thread's tasks (opening a fresh SSH connection per file
    would be far more expensive than the file transfer itself)."""

    def __init__(self, host, port, username, key_filename, password):
        self.host = host
        self.port = port
        self.username = username
        self.key_filename = key_filename
        self.password = password
        self._local = threading.local()

    def get_sftp(self):
        if not hasattr(self._local, "sftp"):
            client = remote_client.connect(
                self.host, self.port, self.username, self.key_filename, self.password
            )
            self._local.client = client
            self._local.sftp = client.open_sftp()
        return self._local.sftp

    def get_client(self):
        """The underlying SSHClient for this thread's connection (for
        native exec commands like remote_client.read_bytes's `cat`, faster
        than SFTP for bulk full-file reads)."""
        self.get_sftp()  # ensures the connection is established
        return self._local.client


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


def _read_prefix(sftp, remote_path, n):
    """Read up to the first `n` bytes of a remote file -- NOT the whole
    file. Returns (data, is_whole_file): is_whole_file is True when fewer
    than `n` bytes came back, meaning EOF was hit and `data` already IS the
    complete file (so a caller needing the full image can skip re-fetching
    it)."""
    with sftp.open(str(remote_path), "rb") as f:
        data = f.read(n)
    return data, len(data) < n


def _exif_timestamp(exif):
    if not exif:
        return None
    try:
        exif_ifd = exif.get_ifd(EXIF_IFD_TAG)
    except Exception:
        exif_ifd = {}
    raw = exif_ifd.get(DATETIME_ORIGINAL_TAG) or exif.get(DATETIME_TOPLEVEL_TAG)
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y:%m:%d %H:%M:%S")
    except Exception:
        return None


def _embedded_thumb_bytes(prefix_data):
    """Best-effort: pull the small EXIF-embedded preview JPEG out of a
    (possibly truncated) file prefix via piexif, without needing the rest of
    the photo. Returns the thumbnail's raw JPEG bytes, or None if this file
    doesn't have one (piexif.load also just raises on non-JPEG/odd input,
    e.g. PNGs -- caught the same way)."""
    try:
        thumb = piexif.load(prefix_data).get("thumbnail")
        return thumb if thumb else None
    except Exception:
        return None


def _hash_worker(pool, file_info, remote_path):
    """Gets both the EXIF timestamp and perceptual hash from as little data
    as possible. Size/mtime come from the walk's listdir_attr (file_info),
    no extra stat() round-trip needed.

    The old version downloaded the ENTIRE photo just to compute a 64x64
    grayscale hash -- multiple MB over SSH to a weak, single-core netbook,
    per photo. Almost every camera/phone JPEG already embeds a small preview
    thumbnail in its EXIF data (see HASH_PREFIX_BYTES), so this reads only a
    bounded prefix, extracts that thumbnail, and hashes IT instead -- full
    download only happens as a fallback when no embedded thumbnail exists.
    Timestamp extraction was already effectively free (EXIF headers are
    always in that same prefix), so it now runs on the prefix too instead of
    needing the full file to be open."""
    info = file_info[remote_path]
    sftp = pool.get_sftp()
    ts = None
    phash = None
    try:
        prefix, is_whole_file = _read_prefix(sftp, remote_path, HASH_PREFIX_BYTES)
        try:
            with Image.open(io.BytesIO(prefix)) as hdr_img:
                ts = _exif_timestamp(hdr_img.getexif())
        except Exception:
            pass

        thumb_bytes = _embedded_thumb_bytes(prefix)
        if thumb_bytes:
            try:
                with Image.open(io.BytesIO(thumb_bytes)) as timg:
                    phash = imagehash.phash(timg)
            except Exception:
                phash = None

        if phash is None:
            full_data = prefix if is_whole_file else remote_client.read_bytes(pool.get_client(), remote_path)
            with Image.open(io.BytesIO(full_data)) as img:
                # draft() only helps JPEGs and only reduces decode scale,
                # never increases it beyond the source size, so it's always
                # safe to call
                img.draft("L", (64, 64))
                phash = imagehash.phash(img)
    except Exception:
        pass
    if ts is None:
        ts = datetime.fromtimestamp(info["mtime"])
    return {"ts": ts.isoformat(), "hash": str(phash) if phash is not None else None, "size": info["size"]}


def _score_worker(pool, remote_path):
    """Sharpness (Laplacian variance) + exposure penalty from a single
    remote read, mirroring python-mvp1's score_photo()."""
    try:
        data = remote_client.read_bytes(pool.get_client(), remote_path)
        with Image.open(io.BytesIO(data)) as img:
            img.draft("L", (512, 512))
            gray = np.asarray(img.convert("L").resize((512, 512)), dtype=np.float64)
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
        return {"sharpness": sharpness, "exposure_penalty": float(exposure)}
    except Exception:
        return {"sharpness": 0.0, "exposure_penalty": 0.0}


def _thumb_worker(pool, remote_path):
    """Mirrors python-mvp1/build_review_html.py's make_thumb_b64()."""
    try:
        data = remote_client.read_bytes(pool.get_client(), remote_path)
        with Image.open(io.BytesIO(data)) as img:
            img.draft("RGB", (THUMB_MAX_DIM * 2, THUMB_MAX_DIM * 2))
            img = ImageOps.exif_transpose(img)
            img.thumbnail((THUMB_MAX_DIM, THUMB_MAX_DIM), Image.LANCZOS)
            img = img.convert("RGB")
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=THUMB_QUALITY, optimize=True)
            return base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception:
        return None


def _load_json(path: Path, default):
    if path.exists():
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return default
    return default


def _save_json(path: Path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f)


def _run_cached_stage(paths, cache_path, worker_fn, *, workers, max_seconds, progress_cb, stage_name):
    """Threaded resumable pass over `paths`: worker_fn(path) -> JSON-able
    value, cached to cache_path. Returns (cache_dict, completed: bool)."""
    cache = _load_json(cache_path, {})
    already = len(paths) - len([p for p in paths if p not in cache])
    if progress_cb:
        progress_cb(stage_name, already, len(paths))

    missing = [p for p in paths if p not in cache]
    if not missing:
        return cache, True

    start = time.monotonic()
    done_this_run = 0
    executor = ThreadPoolExecutor(max_workers=workers)
    futures = {executor.submit(worker_fn, p): p for p in missing}
    try:
        for fut in as_completed(futures):
            p = futures[fut]
            try:
                cache[p] = fut.result()
            except Exception as e:
                print(f"  [{stage_name}] error on {p}: {e}", file=sys.stderr)
                continue
            done_this_run += 1
            if done_this_run % SAVE_EVERY == 0:
                _save_json(cache_path, cache)
                if progress_cb:
                    progress_cb(stage_name, already + done_this_run, len(paths))
                print(f"  [{stage_name}] {done_this_run}/{len(missing)} this run "
                      f"({time.monotonic() - start:.0f}s elapsed)")
            if max_seconds is not None and (time.monotonic() - start) > max_seconds:
                break
    finally:
        executor.shutdown(wait=False, cancel_futures=True)

    _save_json(cache_path, cache)
    completed = all(p in cache for p in paths)
    if progress_cb:
        progress_cb(stage_name, sum(1 for p in paths if p in cache), len(paths))
    print(f"[{stage_name}] {done_this_run} processed this run "
          f"({len(cache)}/{len(paths)} total cached).")
    return cache, completed


def run_scan(remote_folder, out_dir, *, host, port=22, username=None,
             key_filename=None, password=None,
             time_window=TIME_WINDOW, hash_distance=HASH_DISTANCE,
             workers=4, max_seconds=None, progress_cb=None):
    """Runs the full scan pipeline against `remote_folder` on `host`,
    writing/resuming caches under `out_dir`. Never calls sys.exit/os._exit
    itself -- that's the CLI wrapper's job, so this is safe to call from a
    long-lived Flask process. Returns a status dict; on partial completion
    (hit max_seconds mid-stage) returns {"status": "incomplete", "stage": ...}
    so the caller can decide whether to re-invoke."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    hash_cache_path = out_dir / "hash_cache.json"
    score_cache_path = out_dir / "score_cache.json"
    thumb_cache_path = out_dir / "thumb_cache.json"

    pool = ConnectionPool(host, port, username, key_filename, password)
    sftp = pool.get_sftp()

    if progress_cb:
        progress_cb("listing", 0, 0)
    file_info = {d["path"]: d for d in remote_client.list_images(sftp, remote_folder)}
    paths = list(file_info.keys())
    if progress_cb:
        progress_cb("listing", len(paths), len(paths))
    print(f"Found {len(paths)} image files under {remote_folder}.")

    hash_cache, hash_done = _run_cached_stage(
        paths, hash_cache_path, functools.partial(_hash_worker, pool, file_info),
        workers=workers, max_seconds=max_seconds, progress_cb=progress_cb,
        stage_name="hashing",
    )
    if not hash_done:
        return {"status": "incomplete", "stage": "hashing"}

    items = []
    for p in paths:
        e = hash_cache[p]
        items.append({
            "path": p,
            "ts": datetime.fromisoformat(e["ts"]),
            "hash": imagehash.hex_to_hash(e["hash"]) if e["hash"] else None,
            "size": e["size"],
        })

    time_clusters = cluster_by_time(items, time_window)
    all_groups = []
    for tc in time_clusters:
        all_groups.extend(split_by_similarity(tc, hash_distance))
    grouped_paths = sorted({item["path"] for g in all_groups for item in g})
    print(f"{len(all_groups)} duplicate groups, {len(grouped_paths)} photos need scoring/thumbnailing.")

    if progress_cb:
        progress_cb("grouping", len(grouped_paths), len(grouped_paths))

    score_cache, score_done = _run_cached_stage(
        grouped_paths, score_cache_path, functools.partial(_score_worker, pool),
        workers=workers, max_seconds=max_seconds, progress_cb=progress_cb,
        stage_name="scoring",
    )
    if not score_done:
        return {"status": "incomplete", "stage": "scoring"}

    thumb_cache, thumb_done = _run_cached_stage(
        grouped_paths, thumb_cache_path, functools.partial(_thumb_worker, pool),
        workers=workers, max_seconds=max_seconds, progress_cb=progress_cb,
        stage_name="thumbnailing",
    )
    if not thumb_done:
        return {"status": "incomplete", "stage": "thumbnailing"}

    if progress_cb:
        progress_cb("done", len(grouped_paths), len(grouped_paths))
    return {
        "status": "complete",
        "total_images": len(paths),
        "groups": len(all_groups),
        "grouped_photos": len(grouped_paths),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=str, help="Remote folder to scan (recursive)")
    ap.add_argument("--host", type=str, required=True, help="Netbook hostname/IP")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--username", type=str, default="netbook",
                     help="SSH username on the remote machine (default: netbook)")
    ap.add_argument("--key-filename", type=str, default=DEFAULT_KEY_FILENAME,
                     help="Path to a private key file (key-based auth preferred). "
                          f"Default: {DEFAULT_KEY_FILENAME}")
    ap.add_argument("--password", type=str, default=None,
                     help="Fallback password auth if no key is set up")
    ap.add_argument("--out-dir", type=str, required=True, help="Where to write/resume the cache files")
    ap.add_argument("--time-window", type=int, default=TIME_WINDOW,
                     help="Seconds between shots to consider them the same burst (default 120)")
    ap.add_argument("--hash-distance", type=int, default=HASH_DISTANCE,
                     help="Max perceptual-hash Hamming distance to count as visually similar (default 10)")
    ap.add_argument("--workers", type=int, default=4,
                     help="Thread pool size (default 4 -- keep low, see module docstring)")
    ap.add_argument("--max-seconds", type=float, default=None,
                     help="Stop each stage (and save progress) after this many seconds. "
                          "Re-run the same command to resume. Omit to run to completion.")
    args = ap.parse_args()

    def cli_progress(stage, done, total):
        pass  # _run_cached_stage already prints its own progress lines

    result = run_scan(
        args.folder, args.out_dir,
        host=args.host, port=args.port, username=args.username,
        key_filename=args.key_filename, password=args.password,
        time_window=args.time_window, hash_distance=args.hash_distance,
        workers=args.workers, max_seconds=args.max_seconds,
        progress_cb=cli_progress,
    )

    if result["status"] == "incomplete":
        print(f"\nStopped mid-'{result['stage']}' stage (time limit reached). "
              f"Re-run the same command to continue (progress is saved in the cache files).")
        sys.stdout.flush()
        # Some worker threads may still be blocked on slow SSH I/O against
        # the netbook -- os._exit skips normal interpreter shutdown (which
        # would otherwise join those threads and could hang past --max-seconds).
        os._exit(2)

    print(f"\nDone. {result['total_images']} images scanned, "
          f"{result['groups']} duplicate groups found "
          f"({result['grouped_photos']} photos in groups).")
    print(f"Run serve_review.py --out-dir {args.out_dir} to review in a browser.")


if __name__ == "__main__":
    main()
