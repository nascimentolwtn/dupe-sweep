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

- `remote_client.py` — paramiko SSH/SFTP + native-exec helper: connect, a
  non-recursive `list_subdirs()` (folder picker, SFTP — cheap and
  interactive, exactly what SFTP is good at), recursive walks
  (`list_images()` for photos only, `list_files()` for every file, still
  SFTP since these are scoped to one scan/archive folder at a time),
  `move_to_trash()` (move-not-delete, with a `_1`/`_2` collision suffix
  instead of overwriting), `move_tree()` (recursive same-disk relocation
  for archive mode, see below). `read_bytes()` and
  `find_trash_dirs()`/`count_trash()`/`purge_trash()`/`restore_trash()` (see
  Purge/restore mode below) run over **native SSH exec** (`cat`/`find`/
  `rm`/`du`) instead of SFTP — see "Why native SSH exec, not SFTP" below.
- `scan_remote.py` — the heavy lifting: hashes + EXIF-timestamps every image
  found (`hash_cache.json`), clusters by time proximity then visual
  similarity, then scores sharpness/exposure (`score_cache.json`) and
  thumbnails (`thumb_cache.json`) *only* for photos that ended up in a
  group. Threaded and resumable, same as `python-mvp1`. Usable as a CLI or
  imported (`run_scan(...)`) by `serve_review.py`.

  **Hashing is fast because it avoids downloading full photos.** Almost
  every camera/phone JPEG embeds a small EXIF preview thumbnail (a few KB)
  near the start of the file; `_hash_worker` reads only a bounded prefix
  (`HASH_PREFIX_BYTES`, 200KB) over SFTP, pulls that embedded thumbnail out
  with `piexif`, and hashes it instead of the full multi-MB photo —
  measured **~19x faster** against the real netbook (0.5s/photo vs.
  10s/photo for a ~4MB photo). Falls back to downloading and hashing the
  full photo only when no embedded thumbnail exists (rare — mainly PNGs or
  images that never went through a camera pipeline). EXIF timestamp
  extraction also runs on this same prefix now, so it's effectively free.
  Scoring and thumbnailing still need real image data (sharpness detection
  in particular would be meaningless on an already-soft preview thumbnail)
  and are unaffected — but they only run on photos that end up in a
  duplicate group, a small fraction of a typical library, so this was never
  the bottleneck.
- `serve_review.py` — local Flask app (runs on this PC, not the netbook):
  browse the netbook's folders, kick off a scan, review duplicate groups
  with embedded thumbnails, and delete straight from the page (delete goes
  over SSH to the netbook immediately, no CSV/apply-step round trip); also
  hosts archive mode (`/archive/browse`, `/archive/confirm`, `POST
  /archive` — see below) and purge/restore mode (`/purge/browse`,
  `/purge/confirm`, `POST /purge`, `/restore/browse`, `/restore/confirm`,
  `POST /restore` — see below). The review page header shows the folder
  currently being worked on and has a **Re-scan** button that re-runs the
  scan against that same folder (merging with what's already cached). Each
  group also has a **Compare** button — an overlapping before/after slider
  between two full-resolution photos (drag or tap to move the divider, zoom
  and pan in lockstep on both sides, mark either side for deletion), ported
  from the Flutter app's `PhotoSliderCompareScreen`. 2-photo groups get a
  one-click Compare button (only one possible pair); 3+ photo groups
  instead get a purple stage-checkbox on each photo (bottom-right, ported
  from the Flutter app's `PhotoGroupCard`) — tap any two to compare them,
  tap the staged one again to un-stage it. The scanning-progress page shows
  elapsed time and an estimated time remaining for the current stage, based
  on how fast this run's own progress is going (a resumed scan with a lot
  already cached doesn't skew the estimate).

All SFTP/SSH calls from the Flask app share one connection, serialized
behind a lock (`_sftp_call`/`_ssh_call`/`_remote_call` in
`serve_review.py`) — neither `paramiko.SFTPClient` nor issuing overlapping
exec commands on one `SSHClient` is thread-safe, and Flask's dev server
runs each request on its own thread, so two concurrent operations (e.g.
Compare mode loading two full-res photos at once) could otherwise wedge the
shared channel rather than just error. This only serializes remote I/O, not
the whole request.

## Why native SSH exec, not SFTP, for purge/restore/read

`find_trash_dirs()`, `count_trash()`, `purge_trash()`, `restore_trash()`,
and `read_bytes()` run `find`/`rm`/`du`/`cat` over a plain SSH exec channel
instead of SFTP. This mattered in practice: purging `_to_delete` folders
across a large root (the whole `/media/backup` browse root, not just one
photo folder — which on a real backup drive can include a lot that isn't
photos, e.g. `DVDTemp/HD_Games/Backups/...`) took **minutes** walking it
directory-by-directory over SFTP (`listdir_attr()` is one SSH round trip
*per directory*), versus **seconds** for the netbook's own `find` running
natively against its own filesystem in one shot. `read_bytes()` (used by
`/raw` for the lightbox/Compare full-resolution fetch) also moved to `cat`
over exec — it skips SFTP's per-packet request/response framing for what's
otherwise just a bulk sequential byte stream.

SFTP is kept for:
- **Browsing** (`list_subdirs()`) — cheap, one level at a time, and
  genuinely benefits from SFTP's structured `listdir_attr()` (file
  attributes without a second stat) for an interactive folder picker.
- **Scan/archive discovery** (`list_images()`, `list_files()`) — these
  walks are scoped to one folder the user explicitly chose to scan or
  archive, not an entire drive, so they haven't shown the same blowup (and
  changing them would mean re-deriving size/mtime via `find -printf`
  instead of SFTP's structured attributes — a larger change than what was
  actually slow).
- **Per-file rename/collision handling** (`move_to_trash()`, `move_tree()`,
  and `restore_trash()`'s actual moves) — fine-grained, stateful logic
  (`_1`/`_2` suffix on a name collision) that doesn't fit a bulk shell
  command; each individual `rename()` is cheap on its own, so this was
  never the bottleneck. `restore_trash()` is a hybrid: native `find` for
  discovering `_to_delete` folders and their contents, SFTP for the actual
  per-file rename.
- `requirements.txt` — `pillow`, `imagehash`, `numpy`, `paramiko`, `flask`, `piexif`.

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

## Purge/restore mode: deleted photos are only ever moved, never unlinked

`/delete` (and by extension the review page's "Delete marked" button) never
actually removes a file — it moves it into a sibling `_to_delete` folder,
same guarantee `python-mvp1` already has. Nothing purges those folders on
its own; that's a deliberate, separate, opt-in step.

```bash
# open http://127.0.0.1:5000/purge/browse or /restore/browse (also linked
# from the main review page, /browse, and /archive/browse)
```

Both modes share the same three-step flow, rooted at `--start-path` (same
root as the main `/browse`, since `_to_delete` folders can turn up anywhere
a scan/delete happened, not just under `--sync-root`):

1. **`/purge/browse`** / **`/restore/browse`** — folder picker; pick the
   subtree to operate on (e.g. the same folder you scanned and deleted
   from).
2. **`/purge/confirm`** / **`/restore/confirm`** — recursively finds every
   `_to_delete` folder under the chosen path and previews how many folders/
   files/bytes are involved before anything happens.
3. **`POST /purge`** — **permanently deletes** those files (native `rm -rf`
   over SSH exec, see "Why native SSH exec, not SFTP" above) and removes
   the now-empty `_to_delete` folders. This is the one genuinely
   destructive, irreversible operation anywhere in this tool — everything
   else in both `python-mvp1` and `python-mvp2-remote` only ever moves
   files.
   **`POST /restore`** — moves those files back to the folder each was
   deleted from (undoing `move_to_trash()`), renaming on a name collision
   (`_1`/`_2` suffix, same as `move_to_trash()`) instead of overwriting,
   then removes the now-empty `_to_delete` folders.

   Both return a summary: files affected, bytes affected, and (restore
   only) how many were renamed for a collision, plus any per-file errors.

   Both also reconcile the review page's caches afterward (best-effort): any
   already-deleted photo under the chosen path that's no longer sitting in a
   `_to_delete` folder — because it was just purged (gone for good) or
   restored (back in its original folder) — gets dropped from `hash_cache`/
   `score_cache`/`thumb_cache`/`deleted_paths.json`. Since the review page
   reclusters from `hash_cache` fresh on every load, this means the stale
   thumbnail disappears immediately, and if that leaves a duplicate group
   with fewer than 2 photos, the whole group disappears too (a "duplicate"
   of one photo isn't a duplicate). The review page's **Re-scan** button
   triggers this same reconciliation for whatever it just rescanned, so
   photos purged before this reconciliation existed (or where the SSH call
   otherwise failed) get cleaned up retroactively on the next rescan.

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
