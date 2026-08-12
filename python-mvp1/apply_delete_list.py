#!/usr/bin/env python3
"""
apply_delete_list.py

Takes the CSV exported from duplicate_review.html (Windows paths, since
that's what's meaningful to the user) and moves each listed file into a
"_to_delete" subfolder next to it. Never hard-deletes — same safety
guarantee as find_duplicate_photos.py --delete-suggested.
"""

import csv
import sys
from pathlib import Path

LINUX_PREFIX = "/sessions/beautiful-sleepy-brown/mnt/s21_LW"
WIN_PREFIX = r"E:\temp\_07_Photos_Images\s21_LW"


def to_linux_path(win_path: str) -> Path:
    p = win_path
    if p.startswith(WIN_PREFIX):
        rest = p[len(WIN_PREFIX):]
        rest = rest.replace("\\", "/")
        return Path(LINUX_PREFIX + rest)
    raise ValueError(f"Path does not start with expected prefix: {win_path}")


def main():
    csv_path = Path(sys.argv[1])
    rows = list(csv.DictReader(open(csv_path, encoding="utf-8")))
    print(f"{len(rows)} rows in {csv_path}")

    moved, missing, errors = [], [], []
    total_bytes = 0

    for row in rows:
        win_path = row["path"]
        try:
            src = to_linux_path(win_path)
        except ValueError as e:
            errors.append((win_path, str(e)))
            continue

        if not src.exists():
            missing.append(win_path)
            continue

        trash_dir = src.parent / "_to_delete"
        trash_dir.mkdir(exist_ok=True)
        dest = trash_dir / src.name
        if dest.exists():
            # extremely unlikely (filenames are unique per folder) but
            # don't silently overwrite if it ever happens
            i = 1
            while dest.exists():
                dest = trash_dir / f"{src.stem}_{i}{src.suffix}"
                i += 1

        size = src.stat().st_size
        src.rename(dest)
        moved.append(win_path)
        total_bytes += size

    print(f"\nMoved: {len(moved)}")
    print(f"Missing (not found, skipped): {len(missing)}")
    print(f"Errors: {len(errors)}")
    print(f"Space freed from Camera (still recoverable from _to_delete): {total_bytes/1024/1024:.1f} MB")

    if missing:
        print("\nMissing files:")
        for m in missing:
            print(f"  {m}")
    if errors:
        print("\nErrors:")
        for w, e in errors:
            print(f"  {w}: {e}")


if __name__ == "__main__":
    main()
