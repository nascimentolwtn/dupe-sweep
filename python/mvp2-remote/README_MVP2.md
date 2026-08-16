# python-mvp2-remote

Remote-netbook extension of `python-mvp1`'s duplicate-detection pipeline.
Points the same clustering/hashing/scoring logic at a folder on a
network-reachable machine (an old i386 Atom N270 netbook, in the original
case) over SSH/SFTP instead of a local folder, and lets you review and
delete straight from a browser instead of exporting a CSV for a separate
apply-step.

**This folder is not part of the Flutter build.** Same as `python-mvp1`,
it's a sibling tool `flutter build`/`flutter run` never touch.

## Why a separate folder from python-mvp1

The transport is fundamentally different — network I/O plus a running
local server, instead of pure local filesystem access — so this is kept as
a sibling, not merged in. `python-mvp1` stays untouched as the validated
local-folder reference. The clustering/hashing/scoring/thumbnailing logic
in `scan_remote.py` is copied from `python-mvp1`, not imported: if you
change the algorithm in one, mirror it in the other or note the divergence
(same policy `README_MVP1.md` already documents for its relationship to
the Dart app).

## What's here

- `remote_client.py` — paramiko SSH/SFTP helper: connect, a non-recursive
  `list_subdirs()` (folder picker), recursive walks (`list_images()` for
  photos only, `list_files()` for every file), `read_bytes()` (prefetched,
  for fast full-file reads over SSH), `move_to_trash()` (move-not-delete,
  with a `_1`/`_2` collision suffix instead of overwriting), and
  `move_tree()` (recursive same-disk relocation for archive mode, see
  below).
- `scan_remote.py` — the heavy lifting: hashes + EXIF-timestamps every image
  found (`hash_cache.json`), clusters by time proximity then visual
  similarity, then scores sharpness/exposure (`score_cache.json`) and
  thumbnails (`thumb_cache.json`) *only* for photos that ended up in a
  group. Threaded and resumable, same as `python-mvp1`. Usable as a CLI or
  imported (`run_scan(...)`) by `serve_review.py`.
- `serve_review.py` — local Flask app (runs on this PC, not the netbook):
  browse the netbook's folders, kick off a scan, review duplicate groups
  with embedded thumbnails, and delete straight from the page (delete goes
  over SSH to the netbook immediately, no CSV/apply-step round trip); also
  hosts archive mode (`/archive/browse`, `/archive/confirm`, `POST
  /archive`) — see below.
- `requirements.txt` — `pillow`, `imagehash`, `numpy`, `paramiko`, `flask`.

## Prerequisites

- **SSH key-based auth already set up** to the netbook (an environment
  step, not something this code sets up). Password auth is available as a
  fallback via `--password`, but a passwordless key is recommended —
  `serve_review.py` reconnects on every dropped connection and repeated
  password prompts aren't practical for a running server.
- `--key-filename` defaults to the WSL-hosted key
  (`\\wsl.localhost\Ubuntu\home\lw_na\.ssh\id_ed25519`) since paramiko's
  own default lookup only checks the Windows user's `~/.ssh`. Override with
  `--key-filename` or the `DUPESWEEP_SSH_KEY` env var if the key moves or
  you're running this on a different machine.
- Python 3.9+ on this PC (the netbook itself needs nothing beyond the
  `sshd` it's already reachable through — no new dependency is installed
  on it).

## Setup

```bash
cd python/mvp2-remote
python3 -m venv .venv
source .venv/bin/activate   # .venv\Scripts\activate on Windows
pip install -r requirements.txt
```

## Usage

Interactive (recommended — browse, scan, review, delete all in one place):

```bash
python3 serve_review.py --host 192.168.4.36 --out-dir ./run
# username, start-path, and key-filename all default -- see Prerequisites
# open http://127.0.0.1:5000/ in a browser
```

`/browse` lets you navigate the netbook's folders one level at a time and
kick off a scan on whatever folder (and all its subfolders) you land on.
The status page auto-refreshes until the scan is done, then hands off to
the review page.

Power-user CLI shortcut (skip `/browse` if you already know the remote
path):

```bash
python3 scan_remote.py /media/backup/sync_data/Camera \
    --host 192.168.4.36 --out-dir ./run --max-seconds 60
# re-run the same command until it reports done (progress is cached)

python3 serve_review.py --host 192.168.4.36 --out-dir ./run
# open http://127.0.0.1:5000/ — scan is already done, goes straight to review
```

`--out-dir` must match between the two commands so `serve_review.py` finds
the caches `scan_remote.py` wrote.

## Known constraint learned the hard way (same as python-mvp1)

If the netbook's photo folder is under active two-way sync (Syncthing,
etc.), deleting moves files into a `_to_delete` folder *inside* that
synced tree — the sync tool can (and did, once, in the local case) clean
up folders it doesn't recognize as part of the mirror. If the netbook's
backed-up-photos folder is a live sync target, don't run a real delete
pass there until you've moved the photos out of it first — see Archive
mode below.

## Archive mode: move photos out of live sync before deleting

Solves the constraint above: relocates a chosen folder from a live-synced
tree (`--sync-root`, default `/media/backup/sync_data`) into a stable
folder the sync tool never touches (`--archive-root`, default
`/media/backup/archive`), same-disk (`sftp.rename`, instant, no bytes
transferred). Once photos are there, it's safe to delete the phone-side
originals.

```bash
# open http://127.0.0.1:5000/archive/browse (also linked from the main
# review page and the regular /browse page)
```

1. **`/archive/browse`** — same folder-picker as `/browse`, rooted at
   `--sync-root` instead of `--start-path`.
2. **`/archive/confirm`** — before moving anything: shows a file/byte count
   for the chosen folder (optionally narrowed by an from/to date range,
   filtered by file mtime — no EXIF parsing, keeps this feature
   Pillow-free). Has an "Update count" button to re-preview after changing
   dates, separate from "Confirm: move these files".
3. **`POST /archive`** — moves the confirmed folder (preserving its
   subfolder structure) into `--archive-root`, skipping:
   - anything inside a `_to_delete` folder (pending-deletion output from
     the dedup feature, never an archive candidate),
   - anything modified more recently than `--archive-min-age-seconds`
     (default 300) — a guard against moving a file the sync client is
     still writing,
   - and renaming (`_1`/`_2` suffix, same as `move_to_trash()`) instead of
     overwriting on a destination name collision.

   Returns a summary: files moved, bytes moved, skipped-as-recent count,
   renamed-for-collision count, and any per-file errors.

**Operational note from verifying this against the real netbook:**
`/media/backup` here is an NTFS-3g (`fuseblk`) mount with
`user_id=0,group_id=0` — every file appears owned by root regardless of
who created it, so a non-root SSH user cannot backdate/change mtimes
(`touch`/`utime` both fail with `EPERM`) even though the permission bits
allow read/write/rename freely. This doesn't affect normal operation
(archive mode only *reads* mtimes, never sets them), but it's worth
knowing if you ever need to construct test fixtures with specific
timestamps against this netbook.

## Concurrency

Keep `--workers` low (default 4). Each worker opens its own
SSHClient/SFTPClient (paramiko's `SFTPClient` isn't meant to be shared
across threads), and a weak single-core netbook is the real bottleneck
regardless of how many threads this PC throws at it.

## Divergence from python-mvp1

- Deletion is immediate (page → Flask → SSH → netbook), not a CSV export +
  separate `apply_delete_list.py` run.
- Scoring/thumbnailing is staged into `scan_remote.py` itself rather than
  split into a second script (`build_review_html.py`'s job in
  `python-mvp1`), since `serve_review.py` needs all three caches ready
  before it can render the first review page.
- The review page's lightbox fetches full-resolution bytes from `/raw` on
  demand instead of a `file://` link — the browser can't reach the
  netbook's filesystem directly.
