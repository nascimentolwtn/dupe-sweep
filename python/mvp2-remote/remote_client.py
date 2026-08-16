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

import shlex
import stat
import time
from pathlib import PurePosixPath

import paramiko

IMAGE_EXTS = {".jpg", ".jpeg", ".png"}
EXCLUDE_PREFIXES = (".trashed-", ".temp-", ".pending-")
TRASH_DIRNAME = "_to_delete"


def _exec(client, cmd, timeout=120):
    """Run `cmd` on the remote host via SSH exec (not SFTP) and return
    (stdout_bytes, stderr_text, exit_code). Used for whole-tree operations
    (find/rm/du) and bulk file reads (cat) -- these are dramatically faster
    than SFTP's per-item request/response round trips: a `find` under a
    large tree (e.g. purge/restore scanning for _to_delete folders) runs
    natively on the netbook's own filesystem in one shot instead of
    thousands of individual listdir_attr() calls over SFTP, one per
    directory. SFTP is kept for folder *browsing* (list_subdirs, cheap and
    interactive) and for the fine-grained per-file rename/collision
    handling that move_to_trash/restore_trash/move_tree need."""
    _in, out, err = client.exec_command(cmd, timeout=timeout)
    rc = out.channel.recv_exit_status()
    return out.read(), err.read().decode("utf-8", errors="replace"), rc


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


def read_bytes(client, remote_path):
    """Read a whole remote file via SSH exec (`cat`) instead of SFTP --
    streams raw bytes straight over the exec channel, skipping SFTP's
    per-packet request/response framing, which matters for the multi-MB
    full-resolution reads the review page's lightbox/Compare view do on top
    of a slow netbook. Raises IOError (with the remote `cat`'s stderr) if
    the file doesn't exist or isn't readable."""
    data, err, rc = _exec(client, f"cat {shlex.quote(str(remote_path))}")
    if rc != 0:
        raise IOError(err.strip() or f"cat failed (exit {rc})")
    return data


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


def find_trash_dirs(client, root):
    """Every _to_delete folder anywhere under root, as a sorted list of
    paths, via one native `find` call over SSH exec. move_to_trash()
    creates one per parent folder it's ever deleted from, so these can be
    scattered throughout a tree rather than living in one place -- and
    root can be a large tree (the whole browse root, not just one photo
    folder), which is exactly where the old per-directory SFTP walk used
    to take minutes."""
    cmd = f"find {shlex.quote(str(root))} -type d -name {shlex.quote(TRASH_DIRNAME)} 2>/dev/null"
    out, _err, _rc = _exec(client, cmd)
    return sorted(l for l in out.decode("utf-8", errors="replace").splitlines() if l.strip())


def count_trash(client, root):
    """Preview for purge/restore: how many _to_delete folders, files, and
    bytes are under root, without touching anything -- via native
    find/du instead of walking every file over SFTP."""
    trash_dirs = find_trash_dirs(client, root)
    if not trash_dirs:
        return {"dirs": 0, "files": 0, "bytes": 0}
    quoted = " ".join(shlex.quote(d) for d in trash_dirs)
    out, _err, _rc = _exec(client, f"find {quoted} -type f 2>/dev/null | wc -l")
    files = int(out.decode().strip() or 0)
    out, _err, _rc = _exec(
        client,
        f"find {quoted} -type f -printf '%s\\n' 2>/dev/null | awk '{{s+=$1}} END {{print s+0}}'",
    )
    total_bytes = int(out.decode().strip() or 0)
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


def purge_trash(client, root):
    """Find every _to_delete folder under root and permanently remove its
    contents via native find + `rm -rf` over SSH exec -- the one genuinely
    destructive operation in this tool, kept separate and opt-in from
    move_to_trash()'s move-not-delete default. Counts files/bytes up front
    (for the summary) since `rm -rf` itself doesn't report what it deleted.
    Returns a summary dict: dirs_purged, files_removed, bytes_removed,
    errors."""
    trash_dirs = find_trash_dirs(client, root)
    if not trash_dirs:
        return {"dirs_purged": 0, "files_removed": 0, "bytes_removed": 0, "errors": []}

    quoted = " ".join(shlex.quote(d) for d in trash_dirs)
    out, _err, _rc = _exec(client, f"find {quoted} -type f 2>/dev/null | wc -l")
    files_removed = int(out.decode().strip() or 0)
    out, _err, _rc = _exec(
        client,
        f"find {quoted} -type f -printf '%s\\n' 2>/dev/null | awk '{{s+=$1}} END {{print s+0}}'",
    )
    bytes_removed = int(out.decode().strip() or 0)

    _out, err, rc = _exec(client, f"rm -rf {quoted}", timeout=300)
    errors = [(root, err.strip())] if rc != 0 and err.strip() else []

    return {
        "dirs_purged": len(trash_dirs),
        "files_removed": files_removed,
        "bytes_removed": bytes_removed,
        "errors": errors,
    }


def _list_files_native(client, root):
    """Like list_files() but via one native `find` call instead of an SFTP
    walk. Used for the files *within* a single already-found _to_delete
    folder, which is typically small -- the expensive part was always
    finding the _to_delete folders across the whole (possibly huge) root,
    which find_trash_dirs() already fixed; this keeps restore_trash
    consistent with the same native-find approach throughout."""
    cmd = f"find {shlex.quote(str(root))} -type f -printf '%s %p\\n' 2>/dev/null"
    out, _err, _rc = _exec(client, cmd)
    for line in out.decode("utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        size_str, path = line.split(" ", 1)
        yield {"path": path, "size": int(size_str)}


def restore_trash(client, sftp, root):
    """Find every _to_delete folder under root (native find, see
    find_trash_dirs) and move each file back to the folder it was deleted
    from (the parent of the _to_delete folder it landed in) -- undoes
    move_to_trash(). Name collisions at the destination (e.g. a same-named
    file recreated since the delete) get the same _1/_2 suffix treatment as
    move_to_trash(). Renames themselves stay on SFTP -- fine-grained,
    per-file collision handling doesn't fit a bulk shell command, but each
    individual rename is cheap; only the whole-tree discovery needed the
    native-find fix. Now-empty _to_delete folders are removed afterward.
    Returns a summary dict: restored, restored_bytes, collisions_renamed,
    errors."""
    trash_dirs = find_trash_dirs(client, root)
    restored = 0
    restored_bytes = 0
    collisions_renamed = 0
    errors = []

    for trash_dir in trash_dirs:
        parent = trash_dir.rsplit("/", 1)[0]
        for info in _list_files_native(client, trash_dir):
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
