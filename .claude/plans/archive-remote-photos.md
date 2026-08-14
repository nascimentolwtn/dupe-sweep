# Archive-move mode: sync_data → archive on the netbook

## Context

The netbook (`.claude/plans/remote-netbook-dedup.md`, `192.168.4.36`) is
where the phone's photos get synced to (`/media/backup/sync_data`), acting
as the phone's backup. Right now there's no safe way to then free up space
*on the phone* — deleting a photo from the phone while `sync_data` is under
active two-way sync risks the sync tool also removing it from the netbook,
since `sync_data` is a live mirror, not a stable archive. `python-mvp1`'s
README already documents this exact class of risk ("Known constraint
learned the hard way": don't create staging folders inside an
actively-synced tree — the sync tool can clean up things it doesn't
recognize).

This feature adds a mode to move photos out of the volatile `sync_data`
mirror into a stable sibling folder, `/media/backup/archive`, that the sync
tool never touches. Once a photo is there, it's safe to delete the
phone-side original. This is a pure relocation on the netbook's own disk —
no dedup, no scoring, no bytes need to leave the netbook at all — so it's
decoupled from (and can run before or after) the dedup review feature in
`remote-netbook-dedup.md`.

**Decided with user**: this is a new mode in `serve_review.py` (the same
local Flask app already planned for browse/scan/review/delete), reusing its
folder-browsing UI, not a separate script. Selection is manual: the user
browses to a `sync_data` subfolder and optionally narrows by date range,
rather than the tool auto-deciding what's "safe" to archive.

## Design

### Depends on (from `remote-netbook-dedup.md`, must exist first)
- `remote_client.py`'s SSH/SFTP connection helper and recursive remote walk.
- `serve_review.py`'s `/browse` folder-picker page and its underlying
  directory-listing logic.

### `remote_client.py` additions
- `list_subdirs(sftp, path)` — extract the non-recursive
  `listdir_attr()` + `stat.S_ISDIR(...)` directory listing already used by
  `/browse` into a shared helper, so both the scan-target picker and this
  archive picker call the same code instead of duplicating it.
- `move_tree(sftp, src_root, dst_root, min_age_seconds=300)` — recursive
  same-disk move:
  - Walks `src_root` with the same recursive walker `scan_remote.py` uses
    (skip `_to_delete` folders — those are pending-deletion output from the
    dedup feature, not archive candidates).
  - Skips any file whose `st_mtime` is newer than `min_age_seconds` (default
    5 min) — guards against moving a file the sync client is still writing.
  - For each remaining file, computes `dst_root / <path relative to
    src_root>`, creates missing parent directories on the netbook
    (`sftp.mkdir`, ignore already-exists — same pattern as the
    move-to-`_to_delete` helper), and `sftp.rename()`s it — instant, same
    filesystem, no data transfer.
  - Collision handling at the destination mirrors `apply_delete_list.py`'s
    `_1`/`_2` suffix approach (`apply_delete_list.py:51-57`) rather than
    overwriting.
  - Returns a summary dict: moved count/bytes, skipped-recent count,
    skipped-collision-renamed count, errors — same shape as
    `apply_delete_list.py`'s summary print (`apply_delete_list.py:64-67`).

### `serve_review.py` additions
- `GET /archive/browse?path=` — same breadcrumb + subfolder-list UI as
  `/browse` (built on the shared `list_subdirs` helper above), rooted under
  `/media/backup/sync_data`, ending in an "Archive this folder" action
  instead of "Scan this folder".
- `GET /archive/confirm?path=` — before moving anything: recursively counts
  files/bytes under the chosen subfolder (reusing the walk, no image
  opening needed since this feature never touches Pillow), shows that
  count, and exposes optional `date_from`/`date_to` inputs filtered against
  file mtime (not EXIF — no image parsing in this feature, keeps it fast
  and dependency-free). Filtering by mtime is an approximation of capture
  time; acceptable here since the goal is "don't touch files still
  syncing," not precise date grouping.
- `POST /archive` — body `{path, date_from?, date_to?}`, calls
  `move_tree(...)` with the resolved source/destination and any date
  filter applied during the walk, returns the summary to render as a
  confirmation page (moved N photos, X MB — safe to delete these from the
  phone now).

## Open items to confirm before/while implementing (not blocking the plan)

- Exact `min_age_seconds` mid-sync-transfer guard (default 300s proposed —
  adjust based on how the phone's sync client behaves in practice).
- Whether `date_from`/`date_to` should filter by mtime only, or also
  attempt EXIF `DateTimeOriginal` for accuracy at the cost of opening each
  file — leaning mtime-only per above, revisit if it proves inaccurate.

## Docs to update once implemented

Same as `remote-netbook-dedup.md` — this extends the same `CLAUDE.md`/
`README.md` sections that plan already calls for adding, rather than
needing new ones: add the archive mode's routes/behavior to whatever
`python-mvp2-remote` section lands in `CLAUDE.md`, and mention "safe to
delete from phone after archiving" in `README.md`'s feature description.

## Verification

- `move_tree` against the real netbook: confirm subfolder structure is
  preserved under `archive/`, a file modified within `min_age_seconds` is
  correctly skipped, and a destination-collision case gets a renamed
  suffix instead of overwriting.
- `serve_review.py`: browse into a `sync_data` subfolder via
  `/archive/browse`, confirm the `/archive/confirm` count matches what's
  actually there, apply a date-range filter and confirm only matching files
  move, and confirm `_to_delete` folders inside the chosen subfolder are
  left untouched.
