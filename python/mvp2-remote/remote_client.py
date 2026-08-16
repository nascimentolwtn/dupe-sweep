#!/usr/bin/env python3
"""
remote_client.py

SSH/SFTP helper for talking to the netbook that backs up phone photos. The
netbook stays vanilla — no server, no new dependency installed on it, just
the sshd it's already reachable through via paramiko.

Mirrors the recursive-walk and move-not-delete patterns already validated
in python-mvp1/find_duplicate_photos.py and apply_delete_list.py, adapted
for SFTP (which has no os.walk equivalent).
"""

import stat
import time
from pathlib import PurePosixPath

import paramiko

IMAGE_EXTS = {".jpg", ".jpeg", ".png"}
EXCLUDE_PREFIXES = (".trashed-", ".temp-", ".pending-")
TRASH_DIRNAME = "_to_delete"


def connect(host, port=22, username=None, key_filename=None, password=None):
    """Connect over SSH and return the SSHClient. Call .open_sftp() on the
    result to get an SFTP session. Key-based auth is preferred; password is
    a fallback."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        host,
        port=port,
        username=username,
        key_filename=key_filename,
        password=password,
    )
    return client


def list_subdirs(sftp, path):
    """Non-recursive: one level of subfolder names under `path`, sorted.
    Cheap even on the weak netbook, unlike the full recursive walk below —
    used by the folder-picker UI so browsing doesn't have to know the
    target path upfront."""
    entries = sftp.listdir_attr(str(path))
    dirs = [e.filename for e in entries if stat.S_ISDIR(e.st_mode)]
    return sorted(dirs)


def _walk_entries(sftp, root):
    """Shared recursive walk: listdir_attr() + stat.S_ISDIR() recursion
    since paramiko has no os.walk equivalent. Yields (full_path,
    SFTPAttributes) for every *file* under `root` (directories are
    traversed, not yielded), skipping _to_delete staging folders — those
    are pending-deletion output from the dedup feature, never a candidate
    for scanning or archiving."""
    root = str(root)
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            entries = sftp.listdir_attr(current)
        except IOError:
            continue
        for entry in entries:
            name = entry.filename
            full = f"{current.rstrip('/')}/{name}"
            if stat.S_ISDIR(entry.st_mode):
                if name == TRASH_DIRNAME:
                    continue
                stack.append(full)
            else:
                yield full, entry


def _walk_all(sftp, root):
    """Recursive walk yielding (full_path, SFTPAttributes, is_dir) for every
    entry under root, files and directories alike, with no skipping -- used
    by purge/restore, which need to see _to_delete folders themselves
    (unlike _walk_entries, which skips into them)."""
    root = str(root)
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            entries = sftp.listdir_attr(current)
        except IOError:
            continue
        for entry in entries:
            full = f"{current.rstrip('/')}/{entry.filename}"
            is_dir = stat.S_ISDIR(entry.st_mode)
            yield full, entry, is_dir
            if is_dir:
                stack.append(full)


def list_images(sftp, root):
    """Recursive walk mirroring python-mvp1's list_images(). Yields a dict
    per image file with the size/mtime already captured from the listing
    (avoids a second stat() round-trip per file later). Skips hidden/
    trashed/temp files (see _walk_entries for the _to_delete folder skip)."""
    for full, entry in _walk_entries(sftp, root):
        name = full.rsplit("/", 1)[-1]
        if name.startswith(EXCLUDE_PREFIXES):
            continue
        ext = PurePosixPath(name).suffix.lower()
        if ext in IMAGE_EXTS:
            yield {"path": full, "size": entry.st_size, "mtime": entry.st_mtime}


def list_files(sftp, root):
    """Recursive walk yielding every file (any extension, no exclude-prefix
    filtering) under `root` — used by archive-move, which relocates whole
    folder trees rather than cherry-picking photos."""
    for full, entry in _walk_entries(sftp, root):
        yield {"path": full, "size": entry.st_size, "mtime": entry.st_mtime}


def read_bytes(sftp, remote_path):
    """Read a whole remote file into memory, with .prefetch() so paramiko
    pulls it in one bulk transfer instead of chunked one-round-trip-at-a-time
    reads — the difference between usable and painfully slow when reading
    full JPEGs over SSH to/from a weak netbook."""
    with sftp.open(str(remote_path), "rb") as f:
        f.prefetch()
        return f.read()


def _exists(sftp, path):
    try:
        sftp.stat(path)
        return True
    except IOError:
        return False


def _resolve_collision(sftp, dest):
    """If dest exists, append _1, _2, ... before the extension — mirrors
    apply_delete_list.py's collision handling rather than overwriting."""
    base = PurePosixPath(dest)
    stem, suffix = base.stem, base.suffix
    parent = str(base.parent)
    i = 1
    candidate = dest
    while _exists(sftp, candidate):
        candidate = f"{parent}/{stem}_{i}{suffix}"
        i += 1
    return candidate


def move_to_trash(sftp, remote_path):
    """Move (never delete) a remote file into a sibling _to_delete folder,
    same guarantee as python-mvp1's --delete-suggested / apply_delete_list.py.
    Returns the destination path."""
    remote_path = str(remote_path)
    parent = remote_path.rsplit("/", 1)[0] if "/" in remote_path else "."
    name = remote_path.rsplit("/", 1)[-1]
    trash_dir = f"{parent}/{TRASH_DIRNAME}"

    try:
        sftp.mkdir(trash_dir)
    except IOError:
        pass  # already exists

    dest = _resolve_collision(sftp, f"{trash_dir}/{name}")
    sftp.rename(remote_path, dest)
    return dest


def _ensure_dir(sftp, path):
    """mkdir -p equivalent over SFTP: create `path` and any missing
    parents. No-op if it already exists."""
    if not path or path == "/":
        return
    if _exists(sftp, path):
        return
    parent = path.rsplit("/", 1)[0]
    if parent and parent != path:
        _ensure_dir(sftp, parent)
    try:
        sftp.mkdir(path)
    except IOError:
        pass  # created concurrently -- fine either way


def move_tree(sftp, src_root, dst_root, min_age_seconds=300, date_from=None, date_to=None):
    """Recursive same-disk move: relocates every file under src_root to the
    same relative path under dst_root via sftp.rename() — instant, no bytes
    transferred, since both live on the netbook's own disk. Used to move
    photos out of a live-synced folder into a stable archive before it's
    safe to delete them from the phone.

    Skips files modified within the last `min_age_seconds` (default 300s)
    as a guard against moving a file the sync client is still writing.
    `date_from`/`date_to` (unix timestamps, optional) further narrow the
    walk by file mtime. Never deletes — only relocates, with the same
    `_1`/`_2` collision-suffix safety as move_to_trash(). Returns a summary
    dict: moved count/bytes, skipped-recent count, skipped-collision-
    renamed count, errors."""
    src_root = str(src_root).rstrip("/")
    dst_root = str(dst_root).rstrip("/")
    now = time.time()

    moved = 0
    moved_bytes = 0
    skipped_recent = 0
    skipped_collision_renamed = 0
    errors = []

    for info in list_files(sftp, src_root):
        path = info["path"]
        mtime = info["mtime"]
        if date_from is not None and mtime < date_from:
            continue
        if date_to is not None and mtime > date_to:
            continue
        if now - mtime < min_age_seconds:
            skipped_recent += 1
            continue

        rel = path[len(src_root):].lstrip("/")
        dest = f"{dst_root}/{rel}"
        try:
            _ensure_dir(sftp, dest.rsplit("/", 1)[0])
            final_dest = _resolve_collision(sftp, dest)
            if final_dest != dest:
                skipped_collision_renamed += 1
            sftp.rename(path, final_dest)
            moved += 1
            moved_bytes += info["size"]
        except Exception as e:
            errors.append((path, str(e)))

    return {
        "moved": moved,
        "moved_bytes": moved_bytes,
        "skipped_recent": skipped_recent,
        "skipped_collision_renamed": skipped_collision_renamed,
        "errors": errors,
    }


def find_trash_dirs(sftp, root):
    """Every _to_delete folder anywhere under root, as a sorted list of
    paths. move_to_trash() creates one per parent folder it's ever deleted
    from, so these can be scattered throughout a tree rather than living in
    one place."""
    found = []
    for full, _entry, is_dir in _walk_all(sftp, root):
        if is_dir and full.rsplit("/", 1)[-1] == TRASH_DIRNAME:
            found.append(full)
    return sorted(found)


def count_trash(sftp, root):
    """Preview for purge/restore: how many _to_delete folders, files, and
    bytes are under root, without touching anything."""
    trash_dirs = find_trash_dirs(sftp, root)
    files = 0
    total_bytes = 0
    for d in trash_dirs:
        for info in list_files(sftp, d):
            files += 1
            total_bytes += info["size"]
    return {"dirs": len(trash_dirs), "files": files, "bytes": total_bytes}


def _remove_empty_dirs(sftp, root):
    """Remove root and any now-empty subdirectories left after moving files
    out of it, deepest first. Silently skips anything not empty or already
    gone -- best-effort tidy-up, not required for correctness."""
    dirs = [root]
    for full, _entry, is_dir in _walk_all(sftp, root):
        if is_dir:
            dirs.append(full)
    for d in sorted(dirs, key=len, reverse=True):
        try:
            sftp.rmdir(d)
        except IOError:
            pass


def purge_trash(sftp, root):
    """Find every _to_delete folder under root and permanently remove its
    contents -- the one genuinely destructive operation in this tool, kept
    separate and opt-in from move_to_trash()'s move-not-delete default.
    Returns a summary dict: dirs_purged, files_removed, bytes_removed,
    errors."""
    trash_dirs = find_trash_dirs(sftp, root)
    files_removed = 0
    bytes_removed = 0
    errors = []

    for trash_dir in trash_dirs:
        sub_files = []
        sub_dirs = [trash_dir]
        for full, entry, is_dir in _walk_all(sftp, trash_dir):
            if is_dir:
                sub_dirs.append(full)
            else:
                sub_files.append((full, entry.st_size))
        for path, size in sub_files:
            try:
                sftp.remove(path)
                files_removed += 1
                bytes_removed += size
            except Exception as e:
                errors.append((path, str(e)))
        for d in sorted(sub_dirs, key=len, reverse=True):
            try:
                sftp.rmdir(d)
            except Exception as e:
                errors.append((d, str(e)))

    return {
        "dirs_purged": len(trash_dirs),
        "files_removed": files_removed,
        "bytes_removed": bytes_removed,
        "errors": errors,
    }


def restore_trash(sftp, root):
    """Find every _to_delete folder under root and move each file back to
    the folder it was deleted from (the parent of the _to_delete folder it
    landed in) -- undoes move_to_trash(). Name collisions at the
    destination (e.g. a same-named file recreated since the delete) get the
    same _1/_2 suffix treatment as move_to_trash(). Now-empty _to_delete
    folders are removed afterward. Returns a summary dict: restored,
    restored_bytes, collisions_renamed, errors."""
    trash_dirs = find_trash_dirs(sftp, root)
    restored = 0
    restored_bytes = 0
    collisions_renamed = 0
    errors = []

    for trash_dir in trash_dirs:
        parent = trash_dir.rsplit("/", 1)[0]
        for info in list_files(sftp, trash_dir):
            path = info["path"]
            rel = path[len(trash_dir):].lstrip("/")
            dest = f"{parent}/{rel}"
            try:
                _ensure_dir(sftp, dest.rsplit("/", 1)[0])
                final_dest = _resolve_collision(sftp, dest)
                if final_dest != dest:
                    collisions_renamed += 1
                sftp.rename(path, final_dest)
                restored += 1
                restored_bytes += info["size"]
            except Exception as e:
                errors.append((path, str(e)))
        _remove_empty_dirs(sftp, trash_dir)

    return {
        "restored": restored,
        "restored_bytes": restored_bytes,
        "collisions_renamed": collisions_renamed,
        "errors": errors,
    }
