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


def list_images(sftp, root):
    """Recursive walk mirroring python-mvp1's list_images(): listdir_attr()
    + stat.S_ISDIR() recursion since paramiko has no os.walk equivalent.
    Yields a dict per image file with the size/mtime already captured from
    the listing (avoids a second stat() round-trip per file later). Skips
    _to_delete staging folders and hidden/trashed/temp files."""
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
                if name.startswith(EXCLUDE_PREFIXES):
                    continue
                ext = PurePosixPath(name).suffix.lower()
                if ext in IMAGE_EXTS:
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
