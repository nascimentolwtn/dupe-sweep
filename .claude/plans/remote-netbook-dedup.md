# Remote Netbook Dedup — python-mvp1 extension

## Context

An old i386 Atom N270 / 2GB RAM netbook (Python 3.6.9 only) is a backup
destination for phone photos, reachable over LAN via SSH at `192.168.4.36`.
It's too weak to hash/score/thumbnail thousands of photos itself. The goal
is to reuse `python-mvp1`'s already-validated dedup pipeline
(`find_duplicate_photos.py` clustering/hashing/scoring +
`build_review_html.py` review UI) but point it at the netbook's files
instead of a local folder, do all the heavy image work on this PC, and —
unlike `python-mvp1` — trigger delete directly from the review HTML instead
of exporting a CSV for a separate `apply_delete_list.py` run later.

**Decided with user**: transport is SSH/SFTP only (`paramiko`). The netbook
stays vanilla — no server, no new dependency installed on it, just the
`sshd` it's already reachable through. Because browsers can't SSH directly,
a small local Flask server runs on this PC (not the netbook); the review
HTML (served by that same local Flask app, so everything is same-origin —
no CORS) calls it to trigger delete, which then does the SFTP/SSH work
against the netbook. Deletion is always move-to-`_to_delete`, never a hard
delete — same guarantee `python-mvp1` already gives.

## New folder: `python-mvp2-remote/`

Kept as a sibling to `python-mvp1/`, not merged into it — the transport is
fundamentally different (network I/O + a running local server vs. pure
local filesystem), and `python-mvp1` stays untouched as the validated
local-folder reference. Mirrors `python-mvp1`'s file-per-stage shape:

- `remote_client.py` — paramiko connection helper: SSH+SFTP connect
  (key-based auth preferred, via `paramiko.SSHClient` +
  `AutoAddPolicy`/known_hosts), a manual recursive remote walk (paramiko has
  no `os.walk` equivalent — `listdir_attr()` + `stat.S_ISDIR(attr.st_mode)`
  recursion, mirroring `list_images()` in
  `python-mvp1/find_duplicate_photos.py:45-52`), and a move-to-`_to_delete`
  helper (`sftp.mkdir` if missing + `sftp.rename`, mirroring the
  move-not-delete pattern in
  `python-mvp1/apply_delete_list.py:48-60`).
- `scan_remote.py` — equivalent of `find_duplicate_photos.py`, usable both
  as a standalone CLI (power-user shortcut when the folder path is already
  known) and as an importable module: its scan logic lives in a
  `run_scan(remote_folder, out_dir, *, progress_cb=None, ...)` function that
  `main()` calls, so `serve_review.py`'s `/browse` → `/scan` flow can import
  and call it directly on a background thread and pass a `progress_cb` to
  update the in-memory counter the status page polls, instead of shelling
  out to a subprocess. Same resumable-cache architecture (`hash_cache.json`/
  `score_cache.json`/`thumb_cache.json`, threaded, `--max-seconds`
  resumability) but the
  per-file work opens `sftp.open(remote_path)` **with `.prefetch()` before
  handing it to Pillow** instead of a local path — prefetch matters here
  specifically because paramiko's default unprefetched reads are chunked
  one round-trip at a time, which would be painfully slow reading full JPEGs
  over SSH to a weak netbook. Reuses the pure logic from
  `python-mvp1/find_duplicate_photos.py` (copied, not imported, matching
  the project's existing accepted pattern of tolerated divergence between
  parallel implementations — see `README_MVP1.md`'s "mirror or note
  divergence" note, same relationship as the Dart port already has to
  `python-mvp1`):
  - `cluster_by_time` (`find_duplicate_photos.py:120-131`)
  - `split_by_similarity` (`find_duplicate_photos.py:134-152`)
  - the phash/EXIF-timestamp logic from `hash_and_timestamp`
    (`find_duplicate_photos.py:55-84`)
  - the sharpness/exposure math from `score_photo`
    (`find_duplicate_photos.py:93-117`)
  - the thumbnail logic from `build_review_html.py`'s `make_thumb_b64`
    (`build_review_html.py:81-92`)
  - **Concurrency caveat**: keep default `--workers` low (e.g. 3-4). Each
    worker opens its own `SSHClient`/`SFTPClient` (paramiko's `SFTPClient`
    isn't meant to be shared across threads) — and the netbook's single
    Atom core is the real ceiling here regardless of PC-side thread count.
  - **Sync-folder caution**: per `README_MVP1.md`'s "Known constraint
    learned the hard way", if the netbook's photo folder is under active
    sync (Syncthing etc.), the `_to_delete` staging folder must NOT be
    created inside that synced tree — carry this warning into the new
    README and let the user point `_to_delete`'s parent outside it if
    needed.
- `serve_review.py` — local Flask app (PC-side only), the single entry
  point for the whole workflow (browse → scan → review → delete), not just
  review:
  - `GET /browse?path=<remote_path>` — lets the user pick which netbook
    folder to scan instead of having to already know/type the exact remote
    path. Non-recursive per click: one `sftp.listdir_attr(path)` call
    filtered to `stat.S_ISDIR(attr.st_mode)` entries (cheap even on the weak
    netbook, unlike the full recursive walk `scan_remote.py` does once a
    folder is actually chosen). Renders a breadcrumb for the current path,
    a link per subfolder to browse into it, an "up" link, and a
    "Scan this folder (and all subfolders)" button. Defaults to a
    `--start-path` CLI flag (e.g. `/home/user`) so repeat use doesn't start
    at `/` every time.
  - `POST /scan` — triggered by that button with the chosen path. Calls into
    `scan_remote.py` (see below — refactored to expose an importable
    `run_scan(remote_folder, out_dir, ...)` instead of only being
    argparse/CLI-driven) on a background thread, so the existing threaded
    resumable hash/score/thumbnail pipeline runs unchanged; the recursive
    walk in `remote_client.py` naturally covers every subfolder beneath the
    chosen parent. A simple auto-refreshing status page (poll a small
    in-memory progress counter the background thread updates) shows
    "hashed N/M..." until done, then hands off to `GET /`.
  - `GET /` — serves the review HTML built from the caches (same
    group/scoring/thumbnail JSON shape as
    `build_review_html.py`'s `groups_json` at `build_review_html.py:517-539`,
    reusing that HTML/CSS/JS template structure). If no scan has been run
    yet for `--out-dir` (no cache files present), redirects to `/browse`.
  - `POST /delete` — body `{paths: [...]}`, calls the
    `remote_client.py` move-to-trash helper per path over SSH, returns
    per-path success/failure so the page can flip `already_deleted` without
    a reload
  - `GET /raw?path=` — fetches one file's full-res bytes over SFTP
    on-demand (not bulk-cached locally) to power the lightbox, since
    `build_review_html.py`'s `file://` trick
    (`toFileUrl`/`renderLightbox`, `build_review_html.py:186-227`) can't
    reach the netbook's filesystem from the browser
- `requirements.txt` — `pillow`, `imagehash`, `numpy`, `paramiko`, `flask`
- `.gitignore` — mirrors `python-mvp1/.gitignore` (caches/HTML contain real
  paths + embedded thumbnails, must stay untracked)
- `README_MVP2.md` — usage, prerequisites (SSH key-based auth set up to the
  netbook — this is an environment step outside code, flagged as a
  prerequisite not something the code sets up), and the divergence note
  pointing back to `python-mvp1`

### HTML template changes vs. `build_review_html.py`

Copy `HTML_TEMPLATE` (`build_review_html.py:95-433`) as the starting point;
minimal targeted edits:

1. Replace the `export-btn` CSV handler (`build_review_html.py:416-426`)
   with a "Delete marked" button that `POST`s marked, not-yet-deleted paths
   to `/delete` (same-origin now, since Flask serves the page), then applies
   the response to flip `already_deleted` per item and re-renders — reusing
   the existing `already_deleted`/`marked` visual states and
   `already_deleted` exclusion logic already in the template
   (`build_review_html.py:267-269`, `:315-320`) rather than adding new
   states.
2. Replace `toFileUrl`/the `file://` lightbox image src
   (`build_review_html.py:186-190`, `:208`) with a fetch to
   `/raw?path=...` on the local Flask server.
3. Leave localStorage save/resume (`serializeState`/`applyState`/
   `loadFromLocalStorage`, `build_review_html.py:249-281`) untouched — it's
   unaffected by the remote-vs-local source change.

## Open items to confirm before/while implementing (not blocking the plan)

- Netbook's backed-up-photos folder path no longer needs to be known
  upfront — resolved interactively via `/browse` (see `serve_review.py`
  above). `scan_remote.py`'s CLI still accepts an explicit folder arg as a
  power-user shortcut.
- Starting path for `/browse` (`--start-path` default, e.g. `/home/<user>`)
  — pick something reasonable once the netbook's actual layout is known.
- SSH auth: assume key-based; user needs a passwordless key already
  authorized on the netbook (`paramiko` also supports password auth as a
  fallback flag, but key-based is the recommendation).

## Docs to update once implemented

Neither `CLAUDE.md` nor `README.md` currently mentions `python-mvp1` at
all (it's Flutter-app-only documentation today), so this isn't a small
edit — it's a new section in each:

- **`CLAUDE.md`**: add a section documenting `python-mvp2-remote/` as a
  sibling tool (same tier as the existing "Architecture"/"Dependencies"
  sections, but clearly scoped as *not* the Flutter app): what each script
  does (`remote_client.py`, `scan_remote.py`, `serve_review.py`), the
  build/run commands (`pip install -r requirements.txt`, then
  `python3 scan_remote.py <remote-folder> --host 192.168.4.36 ...`,
  `python3 serve_review.py --out-dir ...`), the paramiko/Flask dependency,
  and the move-to-`_to_delete`-never-hard-delete constraint — mirroring how
  the "Build, Run & Test" and "Important Constraints" sections already
  document the Flutter app.
- **`README.md`**: add a section (e.g. "Remote/Netbook Dedup") describing
  the feature in user terms — point the tool at a folder on a
  network-reachable machine over SSH, review in a browser, delete straight
  from the page. Cross-reference `python-mvp1/README_MVP1.md` for the
  local-only variant.

## Verification

- `serve_review.py`'s `/browse`: confirm it lists the netbook's real
  subfolders one level at a time, breadcrumb/"up" navigation works, and
  clicking "Scan this folder" on a chosen parent kicks off a scan that picks
  up photos from every subfolder beneath it (not just files directly in
  that folder).
- `scan_remote.py` against the real netbook (both via `/scan` and run
  directly as a CLI): confirm cache files populate, re-running resumes
  (skips already-cached entries) like `find_duplicate_photos.py` does.
- `serve_review.py`: open `http://127.0.0.1:<port>/` in a browser, confirm
  thumbnails render, lightbox loads full-res via `/raw`, and clicking
  "Delete marked" actually moves the file into `_to_delete` on the netbook
  (verify over a manual `ssh` check) and the card updates to the
  already-deleted state without a page reload.
- Confirm the `_to_delete` folder lands outside any actively-synced tree on
  the netbook before running a real delete pass.
