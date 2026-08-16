#!/usr/bin/env python3
"""
serve_review.py

Local Flask app (runs on this PC, not the netbook) -- the single entry
point for the whole remote-dedup workflow: browse -> scan -> review ->
delete. Everything is same-origin (the review page's JS calls back into
this same server), so there's no CORS to deal with, and delete happens
directly from the page instead of exporting a CSV for a separate
apply_delete_list.py run later like python-mvp1 does.

Routes:
  GET  /browse            folder-picker UI rooted at --start-path
  POST /scan               kicks off scan_remote.run_scan() on a background
                            thread for the chosen path
  GET  /scan/status         auto-refreshing progress page, redirects to / when done
  GET  /                    review UI built from the caches in --out-dir
  POST /delete              {paths: [...]} -> move-to-_to_delete over SFTP
  GET  /raw?path=           full-res bytes for the lightbox
  GET  /archive/browse      folder-picker UI rooted at --sync-root, for
                            picking a folder to move out of live sync
  GET  /archive/confirm     preview: file/byte count for the chosen folder
                            (+ optional date_from/date_to) before moving
  POST /archive             moves the confirmed folder from --sync-root
                            into --archive-root via remote_client.move_tree()
  POST /archive/events/scan     kicks off scan_remote.scan_events() (timestamps +
                                 thumbnails for every photo under the chosen folder)
  GET  /archive/events/scan/status  progress page, redirects to the review page when done
  GET  /archive/events/review       thumbnail-grid review UI: auto-clusters photos into
                                     candidate Events by a time gap (adjustable live in
                                     JS -- recluster/merge/move-file/exclude/rename), only
                                     the final edited grouping is sent to confirm
  POST /archive/events/confirm      {events: [{name, paths}]} -> moves each event's files
                                     into --archive-root/<name>/ via remote_client.move_grouped()
  GET  /purge/browse        folder-picker UI rooted at --start-path, for
                            picking a subtree to purge _to_delete folders in
  GET  /purge/confirm       preview: how many _to_delete folders/files/bytes
                            would be permanently removed under the chosen path
  POST /purge               permanently deletes those files via
                            remote_client.purge_trash() -- the only
                            irreversible operation in this tool
  GET  /restore/browse      folder-picker UI rooted at --start-path, for
                            picking a subtree to restore _to_delete folders in
  GET  /restore/confirm     preview: how many _to_delete folders/files/bytes
                            would be restored under the chosen path
  POST /restore             moves those files back to where they were
                            deleted from via remote_client.restore_trash()

Usage:
    python3 serve_review.py --host 192.168.4.36 --out-dir ./run
    (SSH username defaults to "netbook"; --start-path defaults to /media/backup)

Dependencies: flask, paramiko, pillow, imagehash, numpy (pip install -r requirements.txt)
"""

import argparse
import json
import os
import posixpath
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import imagehash
import paramiko
from flask import Flask, Response, abort, jsonify, redirect, render_template_string, request, url_for
from markupsafe import escape

import remote_client
import scan_remote
from scan_remote import (
    EVENT_GAP_SECONDS, cluster_by_time, cluster_events, run_scan, scan_events, split_by_similarity,
)

# The SSH key lives under the WSL filesystem on this machine, not the
# Windows user's own ~/.ssh (which paramiko searches by default when no
# --key-filename is given). Overridable via DUPESWEEP_SSH_KEY so this isn't
# baked in if the WSL distro/username ever changes.
DEFAULT_KEY_FILENAME = os.environ.get(
    "DUPESWEEP_SSH_KEY",
    r"\\wsl.localhost\Ubuntu\home\lw_na\.ssh\id_ed25519",
)

app = Flask(__name__)

CONFIG = {}

SCAN_LOCK = threading.Lock()
SCAN_STATE = {
    "running": False, "stage": None, "done": 0, "total": 0, "error": None,
    "stage_started_at": None, "stage_baseline_done": 0,
}

# Archive mode's "group into events" flow -- separate lock/state from
# SCAN_STATE above so a dedup scan and an event scan don't collide if
# both are kicked off around the same time.
EVENT_SCAN_LOCK = threading.Lock()
EVENT_SCAN_STATE = {
    "running": False, "stage": None, "done": 0, "total": 0, "error": None,
    "stage_started_at": None, "stage_baseline_done": 0, "root": None,
}

_client_lock = threading.Lock()
_ssh_client = None
_sftp_client = None


def _connect_sftp():
    global _ssh_client, _sftp_client
    _ssh_client = remote_client.connect(
        CONFIG["host"], CONFIG["port"], CONFIG["username"],
        CONFIG["key_filename"], CONFIG["password"],
    )
    _sftp_client = _ssh_client.open_sftp()


def _reset_connection():
    """Drop the shared connection so the next call reconnects. Closes the
    old SSHClient/SFTPClient first -- paramiko's Transport is a running
    daemon thread that holds a reference to itself, so just reassigning the
    globals to None leaks a live authenticated connection (socket + thread)
    forever; every reconnect without this leaked one permanently."""
    global _ssh_client, _sftp_client
    for c in (_sftp_client, _ssh_client):
        if c is not None:
            try:
                c.close()
            except Exception:
                pass
    _sftp_client = None
    _ssh_client = None


def _sftp_call(fn):
    """Call fn(sftp) against the shared connection, serialized behind
    _client_lock for the WHOLE call (not just the connect step) --
    paramiko's SFTPClient isn't thread-safe, and Flask's dev server runs
    request handlers on separate threads, so two concurrent callers (e.g.
    the compare view loading two full-res photos at once) sharing one
    SFTPClient can wedge the underlying channel rather than just raising.
    On a transport error (netbook napped, connection dropped), reconnect
    once and retry, still under the lock."""
    global _sftp_client
    with _client_lock:
        if _sftp_client is None:
            _connect_sftp()
        try:
            return fn(_sftp_client)
        except (IOError, EOFError, paramiko.SSHException):
            _reset_connection()
            _connect_sftp()
            return fn(_sftp_client)


def _ssh_call(fn):
    """Like _sftp_call but hands fn the underlying SSHClient instead of an
    SFTP session, for native find/rm/du exec commands (see
    remote_client.find_trash_dirs/count_trash/purge_trash) -- dramatically
    faster than SFTP's per-item round trips for whole-tree operations like
    purge/restore, which used to take minutes walking a large root
    directory by directory. Shares the same connection/lock/reconnect logic
    as _sftp_call (both ride the same underlying connection)."""
    global _ssh_client
    with _client_lock:
        if _ssh_client is None:
            _connect_sftp()
        try:
            return fn(_ssh_client)
        except (IOError, EOFError, paramiko.SSHException):
            _reset_connection()
            _connect_sftp()
            return fn(_ssh_client)


def _remote_call(fn):
    """Like _sftp_call/_ssh_call but hands fn BOTH the SFTP session and the
    underlying SSHClient in one locked block -- for restore_trash, which
    needs native find for fast whole-tree discovery AND SFTP for the
    per-file rename/collision handling."""
    global _ssh_client, _sftp_client
    with _client_lock:
        if _sftp_client is None:
            _connect_sftp()
        try:
            return fn(_sftp_client, _ssh_client)
        except (IOError, EOFError, paramiko.SSHException):
            _reset_connection()
            _connect_sftp()
            return fn(_sftp_client, _ssh_client)


def _deleted_paths_file():
    return Path(CONFIG["out_dir"]) / "deleted_paths.json"


def _load_deleted_paths():
    p = _deleted_paths_file()
    if p.exists():
        try:
            with open(p, encoding="utf-8") as f:
                return set(json.load(f))
        except Exception:
            return set()
    return set()


def _save_deleted_paths(paths_set):
    with open(_deleted_paths_file(), "w", encoding="utf-8") as f:
        json.dump(sorted(paths_set), f)


def _prune_caches(paths):
    """Remove `paths` (original, pre-delete remote paths) from every cache
    file in out_dir. _build_groups() reclusters from hash_cache.json fresh
    on every render, so dropping an entry here also drops its thumbnail
    (no more stale "already deleted" card) and, if that leaves its group
    with fewer than 2 photos, the whole group -- cluster_by_time() and
    split_by_similarity() already filter out single-photo groups."""
    out_dir = Path(CONFIG["out_dir"])
    paths = set(paths)
    for fname in ("hash_cache.json", "score_cache.json", "thumb_cache.json"):
        f = out_dir / fname
        if not f.exists():
            continue
        with open(f, encoding="utf-8") as fh:
            cache = json.load(fh)
        if any(p in cache for p in paths):
            for p in paths:
                cache.pop(p, None)
            with open(f, "w", encoding="utf-8") as fh:
                json.dump(cache, fh)
    deleted = _load_deleted_paths()
    if deleted & paths:
        _save_deleted_paths(deleted - paths)


def _reconcile_deleted_cache(root):
    """After a purge or restore under `root`, some entries in
    deleted_paths.json (and their hash/score/thumb cache rows) no longer
    reflect reality -- the file is either gone for good (purged) or back in
    its original folder (restored), either way no longer sitting in a
    _to_delete folder. Best-effort: only checks paths already marked
    deleted under `root`, one stat() each."""
    deleted = _load_deleted_paths()
    candidates = [p for p in deleted if p.startswith(root)]
    if not candidates:
        return

    def _find_stale(sftp):
        stale = []
        for orig in candidates:
            parent, name = orig.rsplit("/", 1)
            trashed_guess = f"{parent}/{remote_client.TRASH_DIRNAME}/{name}"
            try:
                sftp.stat(trashed_guess)
            except IOError:
                stale.append(orig)
        return stale

    stale = _sftp_call(_find_stale)
    if stale:
        _prune_caches(stale)


def _scan_root_file():
    return Path(CONFIG["out_dir"]) / "scan_root.json"


def _load_scan_root():
    p = _scan_root_file()
    if p.exists():
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f).get("path")
        except Exception:
            return None
    return None


def _save_scan_root(path):
    with open(_scan_root_file(), "w", encoding="utf-8") as f:
        json.dump({"path": path}, f)


def _event_scan_result_file():
    return Path(CONFIG["out_dir"]) / "event_scan_result.json"


def _load_event_scan_result():
    p = _event_scan_result_file()
    if p.exists():
        try:
            with open(p, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return None
    return None


def _save_event_scan_result(data):
    with open(_event_scan_result_file(), "w", encoding="utf-8") as f:
        json.dump(data, f)


BROWSE_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Browse netbook folders</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; display: flex; align-items: center; gap: 16px; }
  header h1 { font-size: 16px; margin: 0; }
  header a.nav-link { color: #93c5fd; font-size: 13px; text-decoration: none; }
  header a.nav-link:first-of-type { margin-left: auto; }
  header a.nav-link:hover { text-decoration: underline; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  .breadcrumb { font-size: 13px; color: #666; margin-bottom: 16px; word-break: break-all; }
  ul { list-style: none; padding: 0; }
  li { margin-bottom: 6px; }
  a { color: #3b82f6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .scan-btn { margin-bottom: 20px; }
  .scan-btn button { background: #3b82f6; color: #fff; border: none; padding: 10px 16px;
                      border-radius: 6px; font-size: 14px; cursor: pointer; }
  .scan-btn button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
</style></head>
<body>
<header><h1>Browse netbook folders</h1>
  <a class="nav-link" href="{{ url_for('browse') }}">Dedup &rarr;</a>
  <a class="nav-link" href="{{ url_for('archive_browse') }}">Archive &rarr;</a>
  <a class="nav-link" href="{{ url_for('purge_browse') }}">Purge/restore &rarr;</a>
</header>
<main>
  <div class="breadcrumb">{{ path }}</div>
  <form class="scan-btn" method="post" action="{{ url_for('scan') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit">Scan this folder (and all subfolders)</button>
  </form>
  {% if error %}<div class="error">Could not list this folder: {{ error }}</div>{% endif %}
  <ul>
    {% if path != '/' %}<li><a href="{{ url_for('browse', path=parent) }}">.. (up)</a></li>{% endif %}
    {% for d in subdirs %}
      <li><a href="{{ url_for('browse', path=(path.rstrip('/') + '/' + d)) }}">{{ d }}/</a></li>
    {% endfor %}
  </ul>
</main>
</body></html>
"""

STATUS_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="2">
<title>Scanning...</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; background: #1d1f24; color: #fff;
         display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .box { text-align: center; }
  .path { font-size: 13px; color: #aaa; margin-bottom: 14px; max-width: 80vw; word-break: break-all;
          font-family: ui-monospace, Consolas, monospace; }
  .stage { font-size: 20px; margin-bottom: 10px; text-transform: capitalize; }
  .count { font-size: 14px; color: #aaa; }
  .timing { font-size: 13px; color: #888; margin-top: 6px; }
  .error { color: #f87171; margin-top: 16px; max-width: 80vw; word-break: break-all; }
</style></head>
<body><div class="box">
  {% if scan_root %}<div class="path">{{ scan_root }}</div>{% endif %}
  <div class="stage">{{ state.stage or 'starting' }}&hellip;</div>
  <div class="count">{{ state.done }}/{{ state.total }}</div>
  <div class="timing">Elapsed: {{ elapsed }}{% if eta %} &middot; Est. remaining: {{ eta }}{% endif %}</div>
  {% if state.error %}<div class="error">Error: {{ state.error }}</div>{% endif %}
</div></body></html>
"""

# Archive-move mode: a same-disk relocation from the live-synced --sync-root
# into a stable --archive-root, so it's safe to delete the phone-side
# original afterwards without racing the sync client. Reuses list_subdirs
# for the folder picker (same pattern as BROWSE_TEMPLATE above), rooted at
# --sync-root instead of --start-path.
ARCHIVE_BROWSE_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Archive netbook folders</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; display: flex; align-items: center; gap: 16px; }
  header h1 { font-size: 16px; margin: 0; }
  header a.nav-link { color: #93c5fd; font-size: 13px; text-decoration: none; }
  header a.nav-link:first-of-type { margin-left: auto; }
  header a.nav-link:hover { text-decoration: underline; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  .breadcrumb { font-size: 13px; color: #666; margin-bottom: 16px; word-break: break-all; }
  ul { list-style: none; padding: 0; }
  li { margin-bottom: 6px; }
  a { color: #3b82f6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .scan-btn { margin-bottom: 20px; }
  .scan-btn button { background: #3b82f6; color: #fff; border: none; padding: 10px 16px;
                      border-radius: 6px; font-size: 14px; cursor: pointer; }
  .scan-btn button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
</style></head>
<body>
<header><h1>Archive netbook folders</h1>
  <a class="nav-link" href="{{ url_for('browse') }}">Dedup &rarr;</a>
  <a class="nav-link" href="{{ url_for('archive_browse') }}">Archive &rarr;</a>
  <a class="nav-link" href="{{ url_for('purge_browse') }}">Purge/restore &rarr;</a>
</header>
<main>
  <div class="breadcrumb">{{ path }}</div>
  <p style="font-size:13px;color:#666">Moving a folder here relocates it (same-disk, instant) from
    <code>{{ sync_root }}</code> into <code>{{ archive_root }}</code>, out of the way of the live sync
    client, so it's safe to delete the phone-side originals afterwards.</p>
  <form class="scan-btn" method="get" action="{{ url_for('archive_confirm') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit">Archive this folder (and all subfolders)</button>
  </form>
  {% if error %}<div class="error">Could not list this folder: {{ error }}</div>{% endif %}
  <ul>
    {% if can_go_up %}<li><a href="{{ url_for('archive_browse', path=parent) }}">.. (up)</a></li>{% endif %}
    {% for d in subdirs %}
      <li><a href="{{ url_for('archive_browse', path=(path.rstrip('/') + '/' + d)) }}">{{ d }}/</a></li>
    {% endfor %}
  </ul>
</main>
</body></html>
"""

ARCHIVE_CONFIRM_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Confirm archive</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; }
  header h1 { font-size: 16px; margin: 0; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  code { background: #e5e7eb; padding: 2px 5px; border-radius: 4px; }
  label { display: block; margin: 10px 0 4px; font-size: 13px; }
  input[type=date] { padding: 6px 8px; border-radius: 6px; border: 1px solid #ccc; }
  button { border: none; padding: 10px 16px; border-radius: 6px; font-size: 14px; cursor: pointer; margin-top: 16px; margin-right: 10px; }
  button.secondary { background: #444a55; color: #fff; }
  button.danger { background: #dc2626; color: #fff; }
  button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
  .back { display: inline-block; margin-top: 20px; font-size: 13px; color: #3b82f6; text-decoration: none; }
  .back:hover { text-decoration: underline; }
</style></head>
<body>
<header><h1>Confirm archive</h1></header>
<main>
  <p>Source: <code>{{ path }}</code></p>
  {% if error %}<div class="error">{{ error }}</div>{% else %}
  <p><strong>{{ count }}</strong> file(s), <strong>{{ "%.1f"|format(total_bytes / (1024*1024)) }} MB</strong>
     found{% if date_from or date_to %} in the selected date range{% endif %}.</p>
  {% endif %}
  <p>Destination: <code>{{ archive_root }}</code> (mirrors the same subfolder structure). Files
     modified in the last few minutes are skipped automatically (still-syncing guard).</p>
  <form method="get" action="{{ url_for('archive_confirm') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <label>From date (optional): <input type="date" name="date_from" value="{{ date_from }}"></label>
    <label>To date (optional): <input type="date" name="date_to" value="{{ date_to }}"></label>
    <button type="submit" class="secondary">Update count for this date range</button>
    <button type="submit" formaction="{{ url_for('archive_events_scan') }}" formmethod="post"
            style="background:#7c3aed;color:#fff">Group into events first</button>
    <button type="submit" formaction="{{ url_for('do_archive') }}" formmethod="post" class="danger">Confirm: move these files to archive</button>
  </form>
  <p style="font-size:12px;color:#666;margin-top:10px">"Group into events" is for a flat, undated dump of
    photos (like a raw sync folder) -- it splits them into per-occasion albums with a thumbnail review
    before moving. If this folder is already one coherent event, just confirm the move directly above.</p>
  <a class="back" href="{{ url_for('archive_browse', path=path) }}">&larr; back to browse</a>
</main>
</body></html>
"""

ARCHIVE_RESULT_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Archive result</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; }
  header h1 { font-size: 16px; margin: 0; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  code { background: #e5e7eb; padding: 2px 5px; border-radius: 4px; }
  .error { color: #ef4444; margin-bottom: 16px; }
  .ok { color: #16a34a; font-weight: 600; }
  .back { display: inline-block; margin-top: 20px; font-size: 13px; color: #3b82f6; text-decoration: none; }
  .back:hover { text-decoration: underline; }
</style></head>
<body>
<header><h1>Archive result</h1></header>
<main>
  {% if error %}
  <div class="error">Archive failed: {{ error }}</div>
  {% else %}
  <p>Moved <strong>{{ summary.moved }}</strong> file(s)
     (<strong>{{ "%.1f"|format(summary.moved_bytes / (1024*1024)) }} MB</strong>) from
     <code>{{ path }}</code> to <code>{{ dest }}</code>.</p>
  <p>Skipped (modified too recently, possibly still syncing): {{ summary.skipped_recent }}</p>
  <p>Renamed due to a name collision at the destination: {{ summary.skipped_collision_renamed }}</p>
  {% if summary.errors %}
  <div class="error">{{ summary.errors|length }} error(s):<br>
  {% for p, e in summary.errors %}{{ p }}: {{ e }}<br>{% endfor %}
  </div>
  {% endif %}
  <p class="ok">These files are now safe to delete from the phone.</p>
  {% endif %}
  <a class="back" href="{{ url_for('archive_browse') }}">&larr; back to archive browse</a>
</main>
</body></html>
"""

# Archive mode's "group into events" review page: mirrors HTML_TEMPLATE's
# pattern of embedding the full per-file dataset as JSON and doing all
# interactivity in JS against it, only POSTing the final edited result.
# Clustering itself is recomputed client-side (cluster_events()'s sort/
# split logic reimplemented in JS) so changing the gap threshold or
# merging/moving files is instant, no server round-trip.
EVENT_REVIEW_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Group into events</title>
<style>
  :root { color-scheme: light; }
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { position: sticky; top: 0; background: #1d1f24; color: #fff; padding: 14px 20px; z-index: 10;
           display: flex; flex-wrap: wrap; gap: 14px; align-items: center; }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .path { font-size: 12px; opacity: 0.7; font-family: ui-monospace, Consolas, monospace; word-break: break-all; }
  header .gap-control { display: flex; align-items: center; gap: 6px; font-size: 13px; margin-left: auto; }
  header .gap-control input { width: 60px; padding: 5px 6px; border-radius: 6px; border: none; }
  header button { background: #3b82f6; color: #fff; border: none; padding: 8px 14px; border-radius: 6px;
                  font-size: 13px; cursor: pointer; }
  header button.secondary { background: #444a55; }
  header button.danger { background: #dc2626; }
  header button:hover:not(:disabled) { filter: brightness(1.1); }
  header button:disabled { opacity: 0.5; cursor: default; }
  main { padding: 16px; max-width: 1400px; margin: 0 auto; }
  .event-card { background: #fff; border-radius: 10px; padding: 14px 16px; margin-bottom: 14px; box-shadow: 0 1px 2px rgba(0,0,0,.06); }
  .event-header { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
  .event-header input.event-name { font-size: 14px; font-weight: 600; padding: 6px 8px; border-radius: 6px;
                                     border: 1px solid #ccc; min-width: 240px; flex: 0 1 320px; }
  .event-meta { font-size: 12px; color: #666; }
  .event-header .merge-btn { margin-left: auto; background: #444a55; color: #fff; border: none;
                              padding: 6px 12px; border-radius: 6px; font-size: 12px; cursor: pointer; }
  .event-header .merge-btn:hover { filter: brightness(1.1); }
  .files { display: flex; gap: 12px; flex-wrap: wrap; }
  .file-card { width: 170px; border: 2px solid transparent; border-radius: 8px; padding: 6px; position: relative; }
  .file-card.excluded { opacity: 0.4; }
  .file-card img { width: 100%; height: 150px; object-fit: cover; border-radius: 6px; display: block; background: #eee; }
  .file-card .no-thumb { width: 100%; height: 150px; border-radius: 6px; background: #e5e7eb; display: flex;
                          align-items: center; justify-content: center; font-size: 28px; color: #9ca3af; }
  .file-meta { font-size: 10.5px; color: #555; margin-top: 5px; line-height: 1.3; word-break: break-all; }
  .file-controls { display: flex; align-items: center; justify-content: space-between; margin-top: 4px; }
  .file-controls label { font-size: 11px; display: flex; align-items: center; gap: 4px; }
  .file-nav { display: flex; gap: 4px; }
  .file-nav button { background: #eee; border: none; width: 22px; height: 22px; border-radius: 4px;
                      cursor: pointer; font-size: 12px; line-height: 1; }
  .file-nav button:hover:not(:disabled) { background: #ddd; }
  .file-nav button:disabled { opacity: 0.3; cursor: default; }
  .empty { text-align: center; padding: 40px; color: #888; }
  .result-row { padding: 10px 0; border-bottom: 1px solid #eee; font-size: 13px; }
  .result-row .err { color: #ef4444; }
</style>
</head>
<body>
<header>
  <h1>Group into events</h1>
  <span class="path">__SCAN_ROOT__</span>
  <div class="gap-control">
    <label for="gap-input">Split events after a gap of</label>
    <input type="number" id="gap-input" min="1" step="1" value="__GAP_HOURS__">
    <span>hours</span>
    <button id="recluster-btn" class="secondary">Recluster</button>
  </div>
  <button id="confirm-btn" class="danger">Confirm: move these events to archive</button>
</header>
<main id="main"></main>
<script>
const ALL_FILES = __FILES_JSON__;
const ARCHIVE_ROOT = __ARCHIVE_ROOT_JSON__;
let STATE = [];

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function suggestName(startTs, endTs) {
  const fmt = t => new Date(t).toISOString().slice(0, 10);
  const a = fmt(startTs), b = fmt(endTs);
  return a === b ? a : `${a} to ${b}`;
}

function clusterEvents(files, gapSeconds) {
  const images = files.filter(f => f.is_image).slice().sort((a, b) => a.tsMs - b.tsMs);
  const clusters = [];
  let current = [];
  for (const f of images) {
    if (current.length && (f.tsMs - current[current.length - 1].tsMs) / 1000 > gapSeconds) {
      clusters.push(current);
      current = [];
    }
    current.push(f);
  }
  if (current.length) clusters.push(current);

  const events = clusters.map(c => ({
    startTs: c[0].tsMs, endTs: c[c.length - 1].tsMs, files: c.slice(),
  }));

  const others = files.filter(f => !f.is_image);
  for (const o of others) {
    if (events.length === 0) {
      events.push({startTs: o.tsMs, endTs: o.tsMs, files: []});
    }
    let best = 0, bestDist = Infinity;
    events.forEach((e, i) => {
      const dist = (o.tsMs >= e.startTs && o.tsMs <= e.endTs) ? 0
        : Math.min(Math.abs(o.tsMs - e.startTs), Math.abs(o.tsMs - e.endTs));
      if (dist < bestDist) { bestDist = dist; best = i; }
    });
    events[best].files.push(o);
  }

  events.forEach(e => {
    e.files.sort((a, b) => a.tsMs - b.tsMs);
    e.name = suggestName(e.startTs, e.endTs);
  });
  return events;
}

function fileCardHtml(f) {
  const thumb = f.is_image
    ? `<img src="data:image/jpeg;base64,${f.thumb || ''}" loading="lazy">`
    : `<div class="no-thumb">&#128206;</div>`;
  return `
    <div class="file-card ${f.excluded ? 'excluded' : ''}" data-path="${escapeHtml(f.path)}">
      ${thumb}
      <div class="file-meta">${escapeHtml(f.name)}<br>${f.ts.replace('T', ' ').slice(0, 16)}</div>
      <div class="file-controls">
        <label><input type="checkbox" data-action="toggle-exclude" ${f.excluded ? 'checked' : ''}> skip</label>
        <div class="file-nav">
          <button data-action="move-prev" title="Move to previous event">&larr;</button>
          <button data-action="move-next" title="Move to next event">&rarr;</button>
        </div>
      </div>
    </div>`;
}

function eventCardHtml(e, i, total) {
  const files = e.files.map(fileCardHtml).join('');
  return `
    <section class="event-card" data-event-index="${i}">
      <div class="event-header">
        <input class="event-name" data-action="rename" value="${escapeHtml(e.name)}">
        <span class="event-meta">${e.files.length} file(s), ${suggestName(e.startTs, e.endTs)}</span>
        ${i > 0 ? '<button class="merge-btn" data-action="merge-prev">Merge with previous event</button>' : ''}
      </div>
      <div class="files">${files}</div>
    </section>`;
}

function render() {
  const main = document.getElementById('main');
  if (!STATE.length) {
    main.innerHTML = '<div class="empty">No files found for this folder/date range.</div>';
    return;
  }
  main.innerHTML = STATE.map((e, i) => eventCardHtml(e, i, STATE.length)).join('');
}

function recluster() {
  const hours = parseFloat(document.getElementById('gap-input').value) || 12;
  STATE = clusterEvents(ALL_FILES, hours * 3600);
  render();
}

function mergeWithPrevious(idx) {
  if (idx <= 0) return;
  STATE[idx - 1].files = STATE[idx - 1].files.concat(STATE[idx].files);
  STATE.splice(idx, 1);
  render();
}

function moveFile(idx, path, dir) {
  const target = idx + dir;
  if (target < 0 || target >= STATE.length) return;
  const arr = STATE[idx].files;
  const fi = arr.findIndex(f => f.path === path);
  if (fi < 0) return;
  const [f] = arr.splice(fi, 1);
  STATE[target].files.push(f);
  STATE[target].files.sort((a, b) => a.tsMs - b.tsMs);
  if (STATE[idx].files.length === 0) STATE.splice(idx, 1);
  render();
}

document.getElementById('recluster-btn').addEventListener('click', recluster);

document.getElementById('main').addEventListener('click', (ev) => {
  const btn = ev.target.closest('[data-action]');
  if (!btn) return;
  const card = ev.target.closest('.event-card');
  if (!card) return;
  const idx = parseInt(card.dataset.eventIndex, 10);
  const action = btn.dataset.action;
  if (action === 'merge-prev') {
    mergeWithPrevious(idx);
  } else if (action === 'move-prev' || action === 'move-next') {
    const path = ev.target.closest('.file-card').dataset.path;
    moveFile(idx, path, action === 'move-prev' ? -1 : 1);
  }
});

document.getElementById('main').addEventListener('input', (ev) => {
  if (ev.target.dataset.action !== 'rename') return;
  const card = ev.target.closest('.event-card');
  STATE[parseInt(card.dataset.eventIndex, 10)].name = ev.target.value;
});

document.getElementById('main').addEventListener('change', (ev) => {
  if (ev.target.dataset.action !== 'toggle-exclude') return;
  const card = ev.target.closest('.event-card');
  const idx = parseInt(card.dataset.eventIndex, 10);
  const path = ev.target.closest('.file-card').dataset.path;
  const f = STATE[idx].files.find(x => x.path === path);
  if (f) f.excluded = ev.target.checked;
});

document.getElementById('confirm-btn').addEventListener('click', async () => {
  const events = STATE
    .map(e => ({ name: e.name, paths: e.files.filter(f => !f.excluded).map(f => f.path) }))
    .filter(e => e.paths.length > 0);
  if (!events.length) { alert('Nothing to move -- everything is marked "skip".'); return; }
  if (!confirm(`Move ${events.length} event(s) into ${ARCHIVE_ROOT}?`)) return;

  const btn = document.getElementById('confirm-btn');
  btn.disabled = true;
  btn.textContent = 'Moving...';
  document.getElementById('recluster-btn').disabled = true;
  try {
    const resp = await fetch('/archive/events/confirm', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({events}),
    });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || 'Move failed');
    renderResult(data.summaries);
    btn.textContent = 'Done';
  } catch (e) {
    alert('Move failed: ' + e.message);
    btn.disabled = false;
    btn.textContent = 'Confirm: move these events to archive';
    document.getElementById('recluster-btn').disabled = false;
  }
});

function renderResult(summaries) {
  const main = document.getElementById('main');
  main.innerHTML = summaries.map(s => {
    const mb = (s.moved_bytes / (1024 * 1024)).toFixed(1);
    const errs = s.errors && s.errors.length
      ? `<div class="err">${s.errors.length} error(s): ${s.errors.map(e => escapeHtml(e[0] + ': ' + e[1])).join('; ')}</div>`
      : '';
    return `<div class="result-row"><strong>${escapeHtml(s.name)}</strong> &rarr; <code>${escapeHtml(s.dest)}</code><br>
      Moved ${s.moved} file(s) (${mb} MB). Skipped (still syncing): ${s.skipped_recent}.
      Collision-renamed: ${s.skipped_collision_renamed}.${errs}</div>`;
  }).join('') + '<p style="margin-top:16px"><a href="/archive/browse">&larr; back to archive browse</a></p>';
}

for (const f of ALL_FILES) { f.tsMs = new Date(f.ts).getTime(); }
recluster();
</script>
</body></html>
"""

# Purge/restore mode: cleans up _to_delete folders left behind by /delete.
# Purge permanently removes their contents (the one destructive operation in
# this tool); restore undoes a delete by moving files back to where they
# came from. Both share one browse/confirm/result template trio parameterized
# by `mode` ("purge" or "restore") since they're identical apart from wording,
# button danger-styling, and which route they post to.
TRASH_BROWSE_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>{{ 'Purge' if mode == 'purge' else 'Restore' }} deleted photos</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; display: flex; align-items: center; gap: 16px; }
  header h1 { font-size: 16px; margin: 0; }
  header a.nav-link { color: #93c5fd; font-size: 13px; text-decoration: none; }
  header a.nav-link:first-of-type { margin-left: auto; }
  header a.nav-link:hover { text-decoration: underline; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  .breadcrumb { font-size: 13px; color: #666; margin-bottom: 16px; word-break: break-all; }
  p.hint { font-size: 13px; color: #666; }
  ul { list-style: none; padding: 0; }
  li { margin-bottom: 6px; }
  a { color: #3b82f6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .scan-btn { margin-bottom: 20px; }
  .scan-btn button { color: #fff; border: none; padding: 10px 16px; border-radius: 6px; font-size: 14px; cursor: pointer;
                      background: {{ '#dc2626' if mode == 'purge' else '#3b82f6' }}; }
  .scan-btn button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
</style></head>
<body>
<header>
  <h1>{{ 'Purge' if mode == 'purge' else 'Restore' }} deleted photos</h1>
  <a class="nav-link" href="{{ url_for('browse') }}">Dedup &rarr;</a>
  <a class="nav-link" href="{{ url_for('archive_browse') }}">Archive &rarr;</a>
  <a class="nav-link" href="{{ url_for('purge_browse') }}">Purge/restore &rarr;</a>
  <a class="nav-link" href="{{ url_for('restore_browse' if mode == 'purge' else 'purge_browse', path=path) }}">{{ 'Restore mode' if mode == 'purge' else 'Purge mode' }} &rarr;</a>
</header>
<main>
  <div class="breadcrumb">{{ path }}</div>
  <p class="hint">
    {% if mode == 'purge' %}
    Finds every <code>_to_delete</code> folder under here and <strong>permanently</strong> removes its
    contents. This cannot be undone.
    {% else %}
    Finds every <code>_to_delete</code> folder under here and moves its files back to the folder each
    was deleted from.
    {% endif %}
  </p>
  <form class="scan-btn" method="get" action="{{ url_for(mode + '_confirm') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit">Find _to_delete folders here</button>
  </form>
  {% if error %}<div class="error">Could not list this folder: {{ error }}</div>{% endif %}
  <ul>
    {% if path != '/' %}<li><a href="{{ url_for(mode + '_browse', path=parent) }}">.. (up)</a></li>{% endif %}
    {% for d in subdirs %}
      <li><a href="{{ url_for(mode + '_browse', path=(path.rstrip('/') + '/' + d)) }}">{{ d }}/</a></li>
    {% endfor %}
  </ul>
</main>
</body></html>
"""

TRASH_CONFIRM_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Confirm {{ mode }}</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; }
  header h1 { font-size: 16px; margin: 0; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  code { background: #e5e7eb; padding: 2px 5px; border-radius: 4px; }
  button { border: none; padding: 10px 16px; border-radius: 6px; font-size: 14px; cursor: pointer; margin-top: 16px; }
  button.danger { background: #dc2626; color: #fff; }
  button.primary { background: #3b82f6; color: #fff; }
  button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
  .back { display: inline-block; margin-top: 20px; margin-left: 10px; font-size: 13px; color: #3b82f6; text-decoration: none; }
  .back:hover { text-decoration: underline; }
</style></head>
<body>
<header><h1>Confirm {{ mode }}</h1></header>
<main>
  <p>Source: <code>{{ path }}</code></p>
  {% if error %}
  <div class="error">{{ error }}</div>
  {% elif summary.dirs == 0 %}
  <p>No <code>_to_delete</code> folders found under here &mdash; nothing to {{ mode }}.</p>
  {% else %}
  <p><strong>{{ summary.dirs }}</strong> <code>_to_delete</code> folder(s) containing
     <strong>{{ summary.files }}</strong> file(s), <strong>{{ "%.1f"|format(summary.bytes / (1024*1024)) }} MB</strong> total.</p>
  {% if mode == 'purge' %}
  <p>Confirming will <strong>permanently delete</strong> these files. This cannot be undone.</p>
  <form method="post" action="{{ url_for('do_purge') }}"
        onsubmit="return confirm('Permanently delete {{ summary.files }} file(s)? This cannot be undone.');">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit" class="danger">Confirm: permanently delete</button>
  </form>
  {% else %}
  <p>Confirming will move these files back to the folders they were deleted from.</p>
  <form method="post" action="{{ url_for('do_restore') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit" class="primary">Confirm: restore these files</button>
  </form>
  {% endif %}
  {% endif %}
  <a class="back" href="{{ url_for(mode + '_browse', path=path) }}">&larr; back to browse</a>
</main>
</body></html>
"""

TRASH_RESULT_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{{ 'Purge' if mode == 'purge' else 'Restore' }} result</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; }
  header h1 { font-size: 16px; margin: 0; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  code { background: #e5e7eb; padding: 2px 5px; border-radius: 4px; }
  .error { color: #ef4444; margin-bottom: 16px; }
  .ok { color: #16a34a; font-weight: 600; }
  .back { display: inline-block; margin-top: 20px; font-size: 13px; color: #3b82f6; text-decoration: none; }
  .back:hover { text-decoration: underline; }
</style></head>
<body>
<header><h1>{{ 'Purge' if mode == 'purge' else 'Restore' }} result</h1></header>
<main>
  {% if error %}
  <div class="error">{{ mode|capitalize }} failed: {{ error }}</div>
  {% elif mode == 'purge' %}
  <p class="ok">Permanently removed <strong>{{ summary.files_removed }}</strong> file(s)
     (<strong>{{ "%.1f"|format(summary.bytes_removed / (1024*1024)) }} MB</strong>) from
     <strong>{{ summary.dirs_purged }}</strong> <code>_to_delete</code> folder(s) under <code>{{ path }}</code>.</p>
  {% if summary.errors %}
  <div class="error">{{ summary.errors|length }} error(s):<br>
  {% for p, e in summary.errors %}{{ p }}: {{ e }}<br>{% endfor %}
  </div>
  {% endif %}
  {% else %}
  <p class="ok">Restored <strong>{{ summary.restored }}</strong> file(s)
     (<strong>{{ "%.1f"|format(summary.restored_bytes / (1024*1024)) }} MB</strong>) from <code>_to_delete</code>
     back to their original folders under <code>{{ path }}</code>.</p>
  <p>Renamed due to a name collision at the destination: {{ summary.collisions_renamed }}</p>
  {% if summary.errors %}
  <div class="error">{{ summary.errors|length }} error(s):<br>
  {% for p, e in summary.errors %}{{ p }}: {{ e }}<br>{% endfor %}
  </div>
  {% endif %}
  {% endif %}
  <a class="back" href="{{ url_for(mode + '_browse') }}">&larr; back to {{ mode }} browse</a>
</main>
</body></html>
"""

# Adapted from python-mvp1/build_review_html.py's HTML_TEMPLATE: the CSV
# export button becomes a "Delete marked" button that POSTs to /delete, and
# the file:// lightbox trick becomes a fetch to /raw?path=... since the
# browser can't reach the netbook's filesystem directly. localStorage
# save/resume is left untouched -- unaffected by the remote-vs-local source.
HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Duplicate photo review (remote)</title>
<style>
  :root { color-scheme: light; }
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { position: sticky; top: 0; background: #1d1f24; color: #fff; padding: 14px 20px; z-index: 10;
           display: flex; flex-wrap: wrap; gap: 16px; align-items: center; }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .stat { font-size: 13px; opacity: 0.85; }
  header .path { font-size: 12px; opacity: 0.7; font-family: ui-monospace, Consolas, monospace; word-break: break-all; }
  header button { background: #3b82f6; color: #fff; border: none; padding: 8px 14px; border-radius: 6px;
                  font-size: 13px; cursor: pointer; }
  header button.secondary { background: #444a55; }
  header button.danger { background: #dc2626; }
  header button:hover { filter: brightness(1.1); }
  header button.active { background: #f59e0b; }
  main { padding: 16px; max-width: 1400px; margin: 0 auto; }
  .group { background: #fff; border-radius: 10px; padding: 14px 16px; margin-bottom: 14px; box-shadow: 0 1px 2px rgba(0,0,0,.06); }
  .group.reviewed { background: #f0fdf4; }
  .group-header { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 10px; flex-wrap: wrap; gap: 10px; }
  .group-header .title { font-weight: 600; font-size: 14px; }
  .group-header .meta { font-size: 12px; color: #666; }
  .reviewed-toggle { font-size: 12px; display: flex; align-items: center; gap: 4px; cursor: pointer; color: #16a34a; font-weight: 600; }
  .photos { display: flex; gap: 12px; flex-wrap: wrap; }
  .photo-card { width: 210px; border: 2px solid transparent; border-radius: 8px; padding: 6px; position: relative; }
  .photo-card.best { border-color: #22c55e; }
  .photo-card.marked-delete { opacity: 0.55; }
  .photo-card.already-deleted { opacity: 0.4; }
  .photo-thumb-wrap { position: relative; }
  .photo-card img { width: 100%; height: 190px; object-fit: cover; border-radius: 6px; display: block; background: #eee; cursor: zoom-in; }
  .badge { position: absolute; top: 10px; left: 10px; background: #22c55e; color: #fff; font-size: 11px;
           padding: 2px 7px; border-radius: 999px; font-weight: 600; }
  .badge.deleted { background: #ef4444; left: auto; right: 10px; }
  .cmp-stage-btn { position: absolute; bottom: 8px; right: 8px; width: 26px; height: 26px; border: none;
                    border-radius: 5px; background: rgba(0,0,0,0.5); color: #fff; font-size: 15px; line-height: 1;
                    cursor: pointer; display: flex; align-items: center; justify-content: center; padding: 0; }
  .cmp-stage-btn:hover { background: rgba(0,0,0,0.7); }
  .cmp-stage-btn.staged { color: #a78bfa; box-shadow: 0 0 0 2px #8b5cf6 inset; }
  .photo-meta { font-size: 11px; color: #555; margin-top: 6px; line-height: 1.4; word-break: break-all; }
  .photo-check { display: flex; align-items: center; gap: 6px; margin-top: 6px; font-size: 12px; }
  .empty { text-align: center; padding: 40px; color: #888; }

  .lightbox { position: fixed; inset: 0; background: rgba(0,0,0,.85); z-index: 100;
              display: none; align-items: center; justify-content: center; flex-direction: column; }
  .lightbox.open { display: flex; }
  .lightbox img { max-width: 92vw; max-height: 78vh; object-fit: contain; background: #111; border-radius: 4px; }
  .lightbox .lb-meta { color: #eee; font-size: 13px; margin-top: 10px; text-align: center; max-width: 90vw; word-break: break-all; white-space: pre-line; }
  .lightbox .lb-fallback { color: #f59e0b; font-size: 12px; margin-top: 4px; }
  .lightbox .lb-bar { position: absolute; top: 16px; right: 20px; display: flex; gap: 10px; }
  .lightbox .lb-bar button { background: #ffffff22; color: #fff; border: 1px solid #fff5; padding: 6px 12px;
                              border-radius: 6px; cursor: pointer; font-size: 13px; }
  .lightbox .lb-bar button:hover { background: #ffffff3a; }
  .lightbox .lb-nav { position: absolute; top: 50%; transform: translateY(-50%); background: #ffffff22;
                       color: #fff; border: none; font-size: 22px; width: 44px; height: 44px; border-radius: 50%;
                       cursor: pointer; }
  .lightbox .lb-nav:hover { background: #ffffff3a; }
  .lightbox .lb-prev { left: 20px; } .lightbox .lb-next { right: 20px; }
  .lightbox .lb-mark { display: flex; align-items: center; gap: 6px; color: #fff; font-size: 13px; margin-top: 8px; }

  .cmp-open-btn { background: #8b5cf6; color: #fff; border: none; padding: 4px 10px; border-radius: 6px;
                  font-size: 12px; cursor: pointer; }
  .cmp-open-btn:hover { filter: brightness(1.1); }
  .compare-overlay { position: fixed; inset: 0; background: #000; z-index: 200; display: none; flex-direction: column; }
  .compare-overlay.open { display: flex; }
  .compare-topbar { display: flex; align-items: center; gap: 12px; padding: 10px 16px; background: #1d1f24; color: #fff; }
  .compare-topbar .cmp-title { font-size: 14px; font-weight: 600; }
  .compare-topbar .cmp-zoom { margin-left: auto; display: flex; gap: 8px; }
  .compare-topbar button { background: #ffffff22; color: #fff; border: 1px solid #fff5; padding: 6px 12px;
                            border-radius: 6px; cursor: pointer; font-size: 13px; }
  .compare-topbar button:hover:not(:disabled) { background: #ffffff3a; }
  .compare-topbar button:disabled { opacity: 0.4; cursor: default; }
  .cmp-stage { position: relative; flex: 1; overflow: hidden; touch-action: none; cursor: ew-resize; background: #000;
               user-select: none; -webkit-user-select: none; }
  .cmp-layer { position: absolute; top: 0; left: 0; transform-origin: center center; }
  .cmp-layer img { width: 100%; height: 100%; object-fit: contain; display: block; pointer-events: none;
                    -webkit-user-drag: none; user-drag: none; }
  .cmp-clip-left { position: absolute; top: 0; left: 0; bottom: 0; overflow: hidden; }
  .cmp-badge-wrap-right { position: absolute; top: 0; bottom: 0; right: 0; overflow: hidden; pointer-events: none; }
  .cmp-badge { position: absolute; top: 8px; background: #22c55e; color: #fff; font-size: 11px; font-weight: 700;
               padding: 3px 8px; border-radius: 999px; display: none; }
  .cmp-badge.left-pos { left: 8px; }
  .cmp-badge.right-pos { right: 8px; }
  .cmp-divider-line { position: absolute; top: 0; bottom: 0; width: 2px; background: #fff9; pointer-events: none; }
  .cmp-handle { position: absolute; top: 50%; width: 36px; height: 36px; margin-top: -18px; border-radius: 50%;
                background: #fff; color: #111; display: flex; align-items: center; justify-content: center;
                font-size: 16px; pointer-events: none; }
  .cmp-pan { position: absolute; background: #00000066; color: #fff; border: none; width: 36px; height: 36px;
             border-radius: 50%; cursor: pointer; font-size: 14px; display: none; }
  .cmp-pan.show { display: block; }
  .cmp-pan:hover { background: #000000aa; }
  .cmp-pan-up { top: 8px; left: 50%; transform: translateX(-50%); }
  .cmp-pan-down { bottom: 8px; left: 50%; transform: translateX(-50%); }
  .cmp-pan-left { left: 8px; top: 50%; transform: translateY(-50%); }
  .cmp-pan-right { right: 8px; top: 50%; transform: translateY(-50%); }
  .compare-bottombar { display: flex; gap: 16px; padding: 12px 16px; background: #1d1f24; color: #fff;
                        align-items: center; flex-wrap: wrap; }
  .cmp-side { display: flex; align-items: center; gap: 8px; flex: 1; min-width: 220px; }
  .cmp-side select { background: #2a2d35; color: #fff; border: 1px solid #444; border-radius: 6px;
                      padding: 6px 8px; font-size: 12px; flex: 1; }
  .cmp-side label { font-size: 12px; display: flex; align-items: center; gap: 6px; white-space: nowrap; }
</style>
</head>
<body>
<header>
  <h1>Duplicate photo review (remote)</h1>
  <span class="path">__SCAN_ROOT__</span>
  <span class="stat" id="stat-summary">-</span>
  <button id="reset-btn">Reset to AI picks</button>
  <button id="clear-btn" class="secondary">Unmark all (keep everything)</button>
  <button id="hide-reviewed-btn" class="secondary">Hide reviewed groups</button>
  <button id="save-progress-btn" class="secondary">Save progress</button>
  <button id="load-progress-btn" class="secondary">Load progress</button>
  <input type="file" id="load-progress-input" accept="application/json" style="display:none">
  <form method="post" action="/scan" style="display:inline;margin:0">
    <input type="hidden" name="path" value="__SCAN_ROOT__">
    <button type="submit" class="secondary" __RESCAN_ATTRS__ title="Re-scan __SCAN_ROOT__ for new or changed photos">Re-scan</button>
  </form>
  <button id="delete-btn" class="danger">Delete marked</button>
  <a href="/" style="color:#93c5fd;font-size:13px;text-decoration:none;margin-left:auto">Dedup &rarr;</a>
  <a href="/archive/browse" style="color:#93c5fd;font-size:13px;text-decoration:none">Archive &rarr;</a>
  <a href="/purge/browse" style="color:#93c5fd;font-size:13px;text-decoration:none">Purge/restore &rarr;</a>
</header>
<div class="lightbox" id="lightbox">
  <div class="lb-bar">
    <button id="lb-close">Close ✕</button>
  </div>
  <button class="lb-nav lb-prev" id="lb-prev">‹</button>
  <img id="lb-img" src="" alt="">
  <button class="lb-nav lb-next" id="lb-next">›</button>
  <div class="lb-meta" id="lb-meta"></div>
  <div class="lb-fallback" id="lb-fallback"></div>
  <label class="lb-mark"><input type="checkbox" id="lb-mark-cb"> Mark for deletion</label>
</div>
<div class="compare-overlay" id="compare-overlay">
  <div class="compare-topbar">
    <span class="cmp-title">Compare photos</span>
    <div class="cmp-zoom">
      <button id="cmp-zoom-out" title="Zoom out">&minus;</button>
      <button id="cmp-zoom-in" title="Zoom in">+</button>
    </div>
    <button id="cmp-close">Close &#10005;</button>
  </div>
  <div class="cmp-stage" id="cmp-stage">
    <div class="cmp-layer" id="cmp-layer-right"><img id="cmp-img-right" alt="" draggable="false"></div>
    <div class="cmp-badge-wrap-right" id="cmp-badge-wrap-right"><span class="cmp-badge right-pos" id="cmp-badge-right">BEST</span></div>
    <div class="cmp-clip-left" id="cmp-clip-left">
      <div class="cmp-layer" id="cmp-layer-left"><img id="cmp-img-left" alt="" draggable="false"></div>
      <span class="cmp-badge left-pos" id="cmp-badge-left">BEST</span>
    </div>
    <div class="cmp-divider-line" id="cmp-divider-line"></div>
    <div class="cmp-handle" id="cmp-handle">&#8596;</div>
    <button class="cmp-pan cmp-pan-up" id="cmp-pan-up" title="Pan up">&#9650;</button>
    <button class="cmp-pan cmp-pan-down" id="cmp-pan-down" title="Pan down">&#9660;</button>
    <button class="cmp-pan cmp-pan-left" id="cmp-pan-left" title="Pan left">&#9664;</button>
    <button class="cmp-pan cmp-pan-right" id="cmp-pan-right" title="Pan right">&#9654;</button>
  </div>
  <div class="compare-bottombar">
    <div class="cmp-side">
      <select id="cmp-select-left"></select>
      <label><input type="checkbox" id="cmp-mark-left"> Mark for deletion</label>
    </div>
    <div class="cmp-side">
      <select id="cmp-select-right"></select>
      <label><input type="checkbox" id="cmp-mark-right"> Mark for deletion</label>
    </div>
  </div>
</div>
<main id="main"></main>

<script>
const GROUPS = __GROUPS_JSON__;
const STATE_KEY = "dupe_review_remote_state_v1";
let hideReviewed = false;

function fmtMB(bytes) { return (bytes / (1024*1024)).toFixed(1) + " MB"; }
function groupKey(g) { return g.items[0].path; }

let lbGroup = -1, lbItem = -1;

function openLightbox(gi, ii) {
  lbGroup = gi; lbItem = ii;
  renderLightbox();
  document.getElementById("lightbox").classList.add("open");
}
function closeLightbox() {
  document.getElementById("lightbox").classList.remove("open");
  lbGroup = -1; lbItem = -1;
}
function renderLightbox() {
  if (lbGroup < 0) return;
  const g = GROUPS[lbGroup], it = g.items[lbItem];
  const img = document.getElementById("lb-img");
  img.src = "/raw?path=" + encodeURIComponent(it.path);
  img.onerror = () => {
    document.getElementById("lb-fallback").textContent =
      "Could not fetch the full-resolution file from the netbook.";
  };
  img.onload = () => { document.getElementById("lb-fallback").textContent = ""; };
  document.getElementById("lb-meta").textContent =
    `${it.name}  •  ${it.ts}  •  ${(it.size_kb/1024).toFixed(1)} MB  •  score ${it.score.toFixed(0)}`
    + (lbItem === 0 ? "  •  AI pick: BEST" : "")
    + `\n${it.path}`;
  const cb = document.getElementById("lb-mark-cb");
  cb.disabled = !!it.already_deleted;
  cb.checked = !!it.marked;
  cb.onchange = () => {
    it.marked = cb.checked;
    saveToLocalStorage();
    render();
    openLightbox(lbGroup, lbItem); // re-open on same photo after re-render
  };
}
document.getElementById("lb-close").addEventListener("click", closeLightbox);
document.getElementById("lightbox").addEventListener("click", (e) => {
  if (e.target.id === "lightbox") closeLightbox();
});
document.getElementById("lb-prev").addEventListener("click", () => {
  if (lbGroup < 0) return;
  lbItem = (lbItem - 1 + GROUPS[lbGroup].items.length) % GROUPS[lbGroup].items.length;
  renderLightbox();
});
document.getElementById("lb-next").addEventListener("click", () => {
  if (lbGroup < 0) return;
  lbItem = (lbItem + 1) % GROUPS[lbGroup].items.length;
  renderLightbox();
});
document.addEventListener("keydown", (e) => {
  if (lbGroup < 0) return;
  if (e.key === "Escape") closeLightbox();
  if (e.key === "ArrowLeft") document.getElementById("lb-prev").click();
  if (e.key === "ArrowRight") document.getElementById("lb-next").click();
});

// --- compare mode: overlapping 2-photo slider, ported from the Flutter
// app's PhotoSliderCompareScreen. [right] renders full-bleed as the base
// layer; [left] is clipped to a width (growing from the stage's left edge
// as the divider moves right) -- dragging the divider right reveals more of
// [left], dragging left reveals more of [right]. Zoom/pan apply identically
// to both layers (same transform string on both .cmp-layer divs) so the two
// photos stay pixel-aligned as you zoom in to compare detail.
const CMP_MIN_ZOOM = 1.0, CMP_MAX_ZOOM = 4.0, CMP_ZOOM_STEP = 0.5, CMP_PAN_STEP = 40;
let cmpGroup = -1, cmpLeftIdx = -1, cmpRightIdx = -1;
let cmpPos = 0.5, cmpZoom = CMP_MIN_ZOOM, cmpPanX = 0, cmpPanY = 0, cmpDragging = false;

// Bottom-right checkbox on each photo card, ported from the Flutter app's
// PhotoGroupCard._handleCompareCheckboxTap: tapping the first photo in a
// group stages it (turns purple); tapping a second, different photo in the
// SAME group immediately opens Compare for the two and clears staging.
// Tapping the already-staged photo again just un-stages it. Left/right is
// assigned by each photo's position within the group (matching the
// thumbnail row's order), not by which one was tapped first.
function handleCompareStageTap(gi, ii) {
  const g = GROUPS[gi];
  const staged = g.stagedForCompare;
  if (staged === undefined || staged === null) {
    g.stagedForCompare = ii;
    render();
    return;
  }
  if (staged === ii) {
    g.stagedForCompare = null;
    render();
    return;
  }
  g.stagedForCompare = null;
  const left = Math.min(staged, ii), right = Math.max(staged, ii);
  render();
  openCompare(gi, left, right);
}

function openCompare(gi, leftIdx, rightIdx) {
  cmpGroup = gi; cmpLeftIdx = leftIdx; cmpRightIdx = rightIdx;
  cmpPos = 0.5; cmpZoom = CMP_MIN_ZOOM; cmpPanX = 0; cmpPanY = 0;
  populateCompareSelects();
  document.getElementById("compare-overlay").classList.add("open");
  // Layer sizing needs real layout dimensions, which only exist once the
  // overlay has actually been painted (it's `display:none` until the class
  // above is applied) -- hence the rAF instead of sizing synchronously here.
  requestAnimationFrame(() => {
    sizeCompareLayers();
    renderCompare();
  });
}
function closeCompare() {
  document.getElementById("compare-overlay").classList.remove("open");
  cmpGroup = -1;
}
function populateCompareSelects() {
  const g = GROUPS[cmpGroup];
  const optsHtml = g.items.map((it, idx) =>
    `<option value="${idx}">${idx === 0 ? "★ " : ""}${it.name}</option>`).join("");
  const selL = document.getElementById("cmp-select-left");
  const selR = document.getElementById("cmp-select-right");
  selL.innerHTML = optsHtml; selR.innerHTML = optsHtml;
  selL.value = cmpLeftIdx; selR.value = cmpRightIdx;
  // Written back onto the group so the bottom-right picker on the main grid
  // (and a later re-open of Compare) remembers the pair chosen in here.
  selL.onchange = () => { cmpLeftIdx = +selL.value; renderCompare(); };
  selR.onchange = () => { cmpRightIdx = +selR.value; renderCompare(); };
}
function sizeCompareLayers() {
  const stage = document.getElementById("cmp-stage");
  const w = stage.clientWidth + "px", h = stage.clientHeight + "px";
  for (const id of ["cmp-layer-left", "cmp-layer-right"]) {
    const el = document.getElementById(id);
    el.style.width = w; el.style.height = h;
  }
}
function renderCompare() {
  if (cmpGroup < 0) return;
  const g = GROUPS[cmpGroup];
  const left = g.items[cmpLeftIdx], right = g.items[cmpRightIdx];
  document.getElementById("cmp-img-left").src = "/raw?path=" + encodeURIComponent(left.path);
  document.getElementById("cmp-img-right").src = "/raw?path=" + encodeURIComponent(right.path);
  document.getElementById("cmp-badge-left").style.display = cmpLeftIdx === 0 ? "block" : "none";
  document.getElementById("cmp-badge-right").style.display = cmpRightIdx === 0 ? "block" : "none";
  const mL = document.getElementById("cmp-mark-left");
  mL.checked = !!left.marked; mL.disabled = !!left.already_deleted;
  mL.onchange = () => { left.marked = mL.checked; saveToLocalStorage(); render(); };
  const mR = document.getElementById("cmp-mark-right");
  mR.checked = !!right.marked; mR.disabled = !!right.already_deleted;
  mR.onchange = () => { right.marked = mR.checked; saveToLocalStorage(); render(); };
  updateCompareDivider();
  updateCompareTransform();
}
function updateCompareDivider() {
  const stage = document.getElementById("cmp-stage");
  const w = stage.clientWidth;
  const x = w * cmpPos;
  document.getElementById("cmp-clip-left").style.width = x + "px";
  document.getElementById("cmp-badge-wrap-right").style.left = x + "px";
  document.getElementById("cmp-divider-line").style.left = (x - 1) + "px";
  document.getElementById("cmp-handle").style.left = Math.min(Math.max(x - 18, 0), Math.max(w - 36, 0)) + "px";
}
function clampComparePan() {
  const stage = document.getElementById("cmp-stage");
  const maxX = (cmpZoom - 1) * stage.clientWidth / 2;
  const maxY = (cmpZoom - 1) * stage.clientHeight / 2;
  cmpPanX = Math.min(Math.max(cmpPanX, -maxX), maxX);
  cmpPanY = Math.min(Math.max(cmpPanY, -maxY), maxY);
}
function updateCompareTransform() {
  clampComparePan();
  const t = `translate(${cmpPanX}px, ${cmpPanY}px) scale(${cmpZoom})`;
  document.getElementById("cmp-layer-left").style.transform = t;
  document.getElementById("cmp-layer-right").style.transform = t;
  const showPan = cmpZoom > CMP_MIN_ZOOM;
  document.querySelectorAll(".cmp-pan").forEach(b => b.classList.toggle("show", showPan));
  document.getElementById("cmp-zoom-out").disabled = cmpZoom <= CMP_MIN_ZOOM;
  document.getElementById("cmp-zoom-in").disabled = cmpZoom >= CMP_MAX_ZOOM;
}

const cmpStage = document.getElementById("cmp-stage");
function cmpPosFromEvent(e) {
  const rect = cmpStage.getBoundingClientRect();
  cmpPos = Math.min(Math.max((e.clientX - rect.left) / rect.width, 0), 1);
  updateCompareDivider();
}
cmpStage.addEventListener("pointerdown", (e) => {
  cmpDragging = true;
  cmpStage.setPointerCapture(e.pointerId);
  cmpPosFromEvent(e);
});
cmpStage.addEventListener("pointermove", (e) => { if (cmpDragging) cmpPosFromEvent(e); });
cmpStage.addEventListener("pointerup", () => { cmpDragging = false; });
cmpStage.addEventListener("pointercancel", () => { cmpDragging = false; });

document.getElementById("cmp-zoom-in").addEventListener("click", () => {
  cmpZoom = Math.min(cmpZoom + CMP_ZOOM_STEP, CMP_MAX_ZOOM);
  updateCompareTransform();
});
document.getElementById("cmp-zoom-out").addEventListener("click", () => {
  cmpZoom = Math.max(cmpZoom - CMP_ZOOM_STEP, CMP_MIN_ZOOM);
  updateCompareTransform();
});
// Matches PhotoSliderCompareScreen's pan-button offsets exactly (up/left are
// +step, down/right are -step) rather than the more "intuitive" inverse --
// see that file's _clampPan doc comment for why.
document.getElementById("cmp-pan-up").addEventListener("click", () => { cmpPanY += CMP_PAN_STEP; updateCompareTransform(); });
document.getElementById("cmp-pan-down").addEventListener("click", () => { cmpPanY -= CMP_PAN_STEP; updateCompareTransform(); });
document.getElementById("cmp-pan-left").addEventListener("click", () => { cmpPanX += CMP_PAN_STEP; updateCompareTransform(); });
document.getElementById("cmp-pan-right").addEventListener("click", () => { cmpPanX -= CMP_PAN_STEP; updateCompareTransform(); });
document.getElementById("cmp-close").addEventListener("click", closeCompare);
window.addEventListener("resize", () => {
  if (cmpGroup < 0) return;
  sizeCompareLayers();
  updateCompareDivider();
  updateCompareTransform();
});
document.addEventListener("keydown", (e) => {
  if (cmpGroup < 0) return;
  if (e.key === "Escape") closeCompare();
});

// --- persistence: localStorage auto-save/restore, plus explicit export/import
// so progress survives closing the tab, switching browsers, or the page
// getting regenerated with the same underlying photos.
function serializeState() {
  const out = {};
  GROUPS.forEach(g => {
    const items = {};
    g.items.forEach(it => { items[it.path] = it.marked; });
    out[groupKey(g)] = { reviewed: !!g.reviewed, items };
  });
  return out;
}
function applyState(saved) {
  if (!saved) return;
  GROUPS.forEach(g => {
    const gs = saved[groupKey(g)];
    if (!gs) return;
    if (typeof gs.reviewed === "boolean") g.reviewed = gs.reviewed;
    g.items.forEach(it => {
      if (it.already_deleted) return; // not user-editable, always true
      if (gs.items && (it.path in gs.items)) it.marked = gs.items[it.path];
    });
  });
}
function saveToLocalStorage() {
  try { localStorage.setItem(STATE_KEY, JSON.stringify(serializeState())); } catch (e) {}
}
function loadFromLocalStorage() {
  try {
    const raw = localStorage.getItem(STATE_KEY);
    if (raw) applyState(JSON.parse(raw));
  } catch (e) {}
}

function render() {
  const main = document.getElementById("main");
  main.innerHTML = "";
  const visible = GROUPS.map((g, gi) => [g, gi]).filter(([g]) => !(hideReviewed && g.reviewed));
  if (visible.length === 0) {
    main.innerHTML = '<div class="empty">Nothing to show — all groups reviewed. Toggle "Hide reviewed groups" to see them again.</div>';
    updateSummary();
    return;
  }
  visible.forEach(([g, gi]) => {
    const div = document.createElement("div");
    div.className = "group" + (g.reviewed ? " reviewed" : "");
    const header = document.createElement("div");
    header.className = "group-header";
    // Exactly 2 photos: only one possible pair, so a single one-click
    // Compare button beats making the user tap two checkboxes. 3+ photos:
    // no single obvious pair, so each card gets a purple stage-checkbox
    // instead (ported from the Flutter app) -- tap two to compare them.
    const twoPhotoGroup = g.items.length === 2;
    header.innerHTML = `<span class="title">Group ${gi+1} — ${g.ts}</span>
      <span class="meta">${g.items.length} photos</span>
      ${twoPhotoGroup ? '<button class="cmp-open-btn" type="button">&#8644; Compare</button>' : ""}
      <label class="reviewed-toggle">
        <input type="checkbox" class="reviewed-cb" data-group="${gi}" ${g.reviewed ? "checked" : ""}>
        Reviewed
      </label>`;
    if (twoPhotoGroup) {
      header.querySelector(".cmp-open-btn").addEventListener("click", () => openCompare(gi, 0, 1));
    }
    div.appendChild(header);

    const photosDiv = document.createElement("div");
    photosDiv.className = "photos";
    g.items.forEach((it, ii) => {
      const card = document.createElement("div");
      card.className = "photo-card"
        + (ii === 0 ? " best" : "")
        + (it.marked ? " marked-delete" : "")
        + (it.already_deleted ? " already-deleted" : "");
      card.dataset.group = gi;
      card.dataset.item = ii;
      const checkboxHtml = it.already_deleted
        ? `<label class="photo-check">Already moved to _to_delete</label>`
        : `<label class="photo-check">
             <input type="checkbox" ${it.marked ? "checked" : ""} data-group="${gi}" data-item="${ii}">
             Mark for deletion
           </label>`;
      const staged = g.stagedForCompare === ii;
      card.innerHTML = `
        <div class="photo-thumb-wrap">
          ${ii === 0 ? '<span class="badge">BEST</span>' : ""}
          ${it.already_deleted ? '<span class="badge deleted">DELETED</span>' : ""}
          <img src="data:image/jpeg;base64,${it.thumb || ""}" loading="lazy">
          ${!twoPhotoGroup ? `<button class="cmp-stage-btn${staged ? ' staged' : ''}" type="button"
                  title="Select to compare">${staged ? '&#9745;' : '&#9744;'}</button>` : ""}
        </div>
        <div class="photo-meta">${it.name}<br>${it.ts}<br>${(it.size_kb/1024).toFixed(1)} MB, score ${it.score.toFixed(0)}</div>
        ${checkboxHtml}`;
      if (!twoPhotoGroup) {
        card.querySelector(".cmp-stage-btn").addEventListener("click", () => handleCompareStageTap(gi, ii));
      }
      photosDiv.appendChild(card);
    });
    div.appendChild(photosDiv);
    main.appendChild(div);
  });

  main.querySelectorAll('input[type=checkbox]:not(.reviewed-cb)').forEach(cb => {
    cb.addEventListener('change', (e) => {
      const gi = +e.target.dataset.group, ii = +e.target.dataset.item;
      GROUPS[gi].items[ii].marked = e.target.checked;
      saveToLocalStorage();
      updateSummary();
      e.target.closest('.photo-card').classList.toggle('marked-delete', e.target.checked);
    });
  });
  main.querySelectorAll('.photo-card img').forEach(img => {
    img.addEventListener('click', (e) => {
      const card = e.target.closest('.photo-card');
      openLightbox(+card.dataset.group, +card.dataset.item);
    });
  });
  main.querySelectorAll('.reviewed-cb').forEach(cb => {
    cb.addEventListener('change', (e) => {
      const gi = +e.target.dataset.group;
      GROUPS[gi].reviewed = e.target.checked;
      saveToLocalStorage();
      if (hideReviewed) render(); else {
        updateSummary();
        e.target.closest('.group').classList.toggle('reviewed', e.target.checked);
      }
    });
  });
  updateSummary();
}

function updateSummary() {
  let pendingCount = 0, pendingBytes = 0, deletedCount = 0, deletedBytes = 0, reviewedGroups = 0;
  GROUPS.forEach(g => {
    if (g.reviewed) reviewedGroups++;
    g.items.forEach(it => {
      if (it.already_deleted) { deletedCount++; deletedBytes += it.size_kb*1024; }
      else if (it.marked) { pendingCount++; pendingBytes += it.size_kb*1024; }
    });
  });
  document.getElementById("stat-summary").textContent =
    `${GROUPS.length} groups (${reviewedGroups} reviewed) — ${pendingCount} pending deletion (${fmtMB(pendingBytes)}), `
    + `${deletedCount} already deleted (${fmtMB(deletedBytes)})`;
}

document.getElementById("reset-btn").addEventListener("click", () => {
  GROUPS.forEach(g => g.items.forEach((it, ii) => { if (!it.already_deleted) it.marked = ii !== 0; }));
  saveToLocalStorage();
  render();
});
document.getElementById("clear-btn").addEventListener("click", () => {
  GROUPS.forEach(g => g.items.forEach(it => { if (!it.already_deleted) it.marked = false; }));
  saveToLocalStorage();
  render();
});
document.getElementById("hide-reviewed-btn").addEventListener("click", (e) => {
  hideReviewed = !hideReviewed;
  e.target.classList.toggle("active", hideReviewed);
  e.target.textContent = hideReviewed ? "Show reviewed groups" : "Hide reviewed groups";
  render();
});
document.getElementById("save-progress-btn").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify(serializeState(), null, 2)], {type: "application/json"});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "review_progress.json";
  a.click();
});
document.getElementById("load-progress-btn").addEventListener("click", () => {
  document.getElementById("load-progress-input").click();
});
document.getElementById("load-progress-input").addEventListener("change", (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    try {
      applyState(JSON.parse(reader.result));
      saveToLocalStorage();
      render();
    } catch (err) { alert("Could not read that file: " + err); }
  };
  reader.readAsText(file);
  e.target.value = "";
});
document.getElementById("delete-btn").addEventListener("click", () => {
  const toDelete = [];
  GROUPS.forEach(g => g.items.forEach(it => {
    if (it.marked && !it.already_deleted) toDelete.push(it.path);
  }));
  if (toDelete.length === 0) { alert("Nothing marked for deletion."); return; }
  if (!confirm(`Delete ${toDelete.length} photo(s)? They will be moved to a _to_delete folder on the netbook, not permanently deleted.`)) return;
  fetch("/delete", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({paths: toDelete}),
  })
    .then(r => r.json())
    .then(results => {
      const failed = [];
      GROUPS.forEach(g => g.items.forEach(it => {
        if (it.path in results) {
          if (results[it.path]) it.already_deleted = true;
          else failed.push(it.path);
        }
      }));
      saveToLocalStorage();
      render();
      if (failed.length) alert(`${failed.length} file(s) failed to delete:\\n` + failed.join("\\n"));
    })
    .catch(err => alert("Delete request failed: " + err));
});

loadFromLocalStorage();
render();
</script>
</body>
</html>
"""


def _build_groups(hash_cache, score_cache, thumb_cache, deleted, time_window, hash_distance, scope_root=None):
    """`hash_cache` accumulates every photo ever scanned into this out_dir,
    across however many different folders -- re-scanning folder B after
    folder A doesn't remove A's entries, it just adds B's. Without
    `scope_root`, the review page would keep showing every folder ever
    scanned in this session merged together (and since nothing ever prunes
    it, whichever folder was scanned first tends to dominate, making later
    folders look like they never took effect). `scope_root` limits this
    build to photos under the folder actually being reviewed right now."""
    root_prefix = f"{scope_root.rstrip('/')}/" if scope_root else None
    items = []
    for path, e in hash_cache.items():
        if root_prefix and not path.startswith(root_prefix):
            continue
        items.append({
            "path": path,
            "ts": datetime.fromisoformat(e["ts"]),
            "hash": imagehash.hex_to_hash(e["hash"]) if e["hash"] else None,
            "size": e["size"],
        })

    time_clusters = cluster_by_time(items, time_window)
    all_groups = []
    for tc in time_clusters:
        all_groups.extend(split_by_similarity(tc, hash_distance))

    for g in all_groups:
        for item in g:
            s = score_cache.get(item["path"], {"sharpness": 0.0, "exposure_penalty": 0.0})
            item["score"] = s["sharpness"] - s["exposure_penalty"]
        g.sort(key=lambda x: x["score"], reverse=True)

    groups_json = []
    for g in all_groups:
        items_out = []
        for idx, item in enumerate(g):
            already_deleted = item["path"] in deleted
            items_out.append({
                "path": item["path"],
                "name": item["path"].rsplit("/", 1)[-1],
                "ts": item["ts"].strftime("%Y-%m-%d %H:%M:%S"),
                "size_kb": round(item["size"] / 1024, 1),
                "score": item["score"],
                "thumb": thumb_cache.get(item["path"]) or "",
                "marked": already_deleted or idx != 0,
                "already_deleted": already_deleted,
            })
        reviewed_default = all(it["already_deleted"] for it in items_out[1:]) if len(items_out) > 1 else True
        groups_json.append({
            "ts": g[0]["ts"].strftime("%Y-%m-%d %H:%M:%S"),
            "reviewed": reviewed_default,
            "items": items_out,
        })
    return groups_json


@app.route("/browse")
def browse():
    path = request.args.get("path", CONFIG["start_path"])
    path = posixpath.normpath(path)
    try:
        subdirs = _sftp_call(lambda sftp: remote_client.list_subdirs(sftp, path))
        error = None
    except Exception as e:
        subdirs = []
        error = str(e)
    parent = posixpath.dirname(path.rstrip("/")) or "/"
    return render_template_string(BROWSE_TEMPLATE, path=path, subdirs=subdirs, parent=parent, error=error)


@app.route("/scan", methods=["POST"])
def scan():
    path = request.form.get("path")
    with SCAN_LOCK:
        if SCAN_STATE["running"]:
            return redirect(url_for("scan_status"))
        now = time.time()
        SCAN_STATE.update({
            "running": True, "stage": "starting", "done": 0, "total": 0, "error": None,
            "stage_started_at": now, "stage_baseline_done": 0,
        })
    _save_scan_root(path)

    def progress_cb(stage, done, total):
        # Reset the per-stage clock/baseline on every stage transition (e.g.
        # hashing -> scoring) so the ETA math below is based on how fast
        # THIS stage is progressing, not skewed by whatever came before it
        # or by items already cached from a previous, resumed run.
        if SCAN_STATE.get("stage") != stage:
            SCAN_STATE["stage_started_at"] = time.time()
            SCAN_STATE["stage_baseline_done"] = done
        SCAN_STATE.update({"stage": stage, "done": done, "total": total})

    def worker():
        try:
            run_scan(
                path, CONFIG["out_dir"],
                host=CONFIG["host"], port=CONFIG["port"], username=CONFIG["username"],
                key_filename=CONFIG["key_filename"], password=CONFIG["password"],
                time_window=CONFIG["time_window"], hash_distance=CONFIG["hash_distance"],
                workers=CONFIG["workers"], max_seconds=None,
                progress_cb=progress_cb,
            )
            try:
                # A rescan is also the natural moment to clean up cache rows
                # left behind by a purge/restore that happened before this
                # folder had reconciliation wired up (or whose SSH call
                # failed) -- best-effort, must not fail the scan itself.
                _reconcile_deleted_cache(path)
            except Exception:
                pass
            SCAN_STATE["stage"] = "done"
        except Exception as e:
            SCAN_STATE["error"] = str(e)
        finally:
            SCAN_STATE["running"] = False

    threading.Thread(target=worker, daemon=True).start()
    return redirect(url_for("scan_status"))


def _fmt_duration(seconds):
    seconds = max(int(seconds), 0)
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    if m < 60:
        return f"{m}m {s}s"
    h, m = divmod(m, 60)
    return f"{h}h {m}m"


@app.route("/scan/status")
def scan_status():
    if not SCAN_STATE["running"] and SCAN_STATE["stage"] == "done" and not SCAN_STATE["error"]:
        return redirect(url_for("review"))

    now = time.time()
    stage_started_at = SCAN_STATE.get("stage_started_at") or now
    stage_elapsed = now - stage_started_at
    done, total = SCAN_STATE["done"], SCAN_STATE["total"]
    baseline = SCAN_STATE.get("stage_baseline_done", 0)
    progressed = max(done - baseline, 0)
    eta = None
    if progressed > 0 and total > done:
        rate = stage_elapsed / progressed
        eta = _fmt_duration(rate * (total - done))

    return render_template_string(
        STATUS_TEMPLATE, state=SCAN_STATE, scan_root=_load_scan_root(),
        elapsed=_fmt_duration(stage_elapsed), eta=eta,
    )


@app.route("/")
def review():
    out_dir = Path(CONFIG["out_dir"])
    if not (out_dir / "hash_cache.json").exists():
        return redirect(url_for("browse"))
    if SCAN_STATE["running"]:
        return redirect(url_for("scan_status"))

    with open(out_dir / "hash_cache.json", encoding="utf-8") as f:
        hash_cache = json.load(f)
    score_cache = {}
    if (out_dir / "score_cache.json").exists():
        with open(out_dir / "score_cache.json", encoding="utf-8") as f:
            score_cache = json.load(f)
    thumb_cache = {}
    if (out_dir / "thumb_cache.json").exists():
        with open(out_dir / "thumb_cache.json", encoding="utf-8") as f:
            thumb_cache = json.load(f)
    deleted = _load_deleted_paths()
    scan_root = _load_scan_root() or ""

    groups_json = _build_groups(
        hash_cache, score_cache, thumb_cache, deleted,
        CONFIG["time_window"], CONFIG["hash_distance"],
        scope_root=scan_root,
    )

    # Escape "</" so a base64 thumbnail can never accidentally contain a
    # literal "</script>" and truncate the inline script block.
    groups_json_str = json.dumps(groups_json).replace("</", "<\\/")
    html = HTML_TEMPLATE.replace("__GROUPS_JSON__", groups_json_str)
    html = html.replace("__SCAN_ROOT__", str(escape(scan_root)))
    html = html.replace("__RESCAN_ATTRS__", "" if scan_root else "disabled")
    return html


@app.route("/delete", methods=["POST"])
def delete():
    body = request.get_json(force=True) or {}
    paths = body.get("paths", [])
    deleted = _load_deleted_paths()
    results = {}
    for p in paths:
        try:
            _sftp_call(lambda sftp: remote_client.move_to_trash(sftp, p))
            deleted.add(p)
            results[p] = True
        except Exception:
            results[p] = False
    _save_deleted_paths(deleted)
    return jsonify(results)


@app.route("/raw")
def raw():
    path = request.args.get("path")
    if not path:
        abort(400)
    try:
        data = _sftp_call(lambda sftp: remote_client.read_bytes(sftp, path))
    except Exception:
        abort(404)
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    mimetype = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}.get(ext, "application/octet-stream")
    return Response(data, mimetype=mimetype)


def _parse_date_range(date_from_str, date_to_str):
    """Parse optional YYYY-MM-DD strings (as produced by <input type=date>)
    into unix timestamps for filtering by file mtime. date_to is treated as
    inclusive of the whole day. Returns (from_ts, to_ts, error_message)."""
    from_ts = to_ts = None
    try:
        if date_from_str:
            from_ts = datetime.strptime(date_from_str, "%Y-%m-%d").timestamp()
        if date_to_str:
            to_ts = (datetime.strptime(date_to_str, "%Y-%m-%d") + timedelta(days=1)).timestamp()
    except ValueError:
        return None, None, "Invalid date format (expected YYYY-MM-DD)."
    return from_ts, to_ts, None


@app.route("/archive/browse")
def archive_browse():
    path = request.args.get("path", CONFIG["sync_root"])
    path = posixpath.normpath(path)
    try:
        subdirs = _sftp_call(lambda sftp: remote_client.list_subdirs(sftp, path))
        error = None
    except Exception as e:
        subdirs = []
        error = str(e)
    parent = posixpath.dirname(path.rstrip("/")) or "/"
    # Keep the picker inside the sync tree -- archiving only makes sense
    # relative to --sync-root, so don't offer an "up" past it.
    can_go_up = path != CONFIG["sync_root"] and path.startswith(CONFIG["sync_root"])
    return render_template_string(
        ARCHIVE_BROWSE_TEMPLATE, path=path, subdirs=subdirs, parent=parent, error=error,
        can_go_up=can_go_up, sync_root=CONFIG["sync_root"], archive_root=CONFIG["archive_root"],
    )


@app.route("/archive/confirm")
def archive_confirm():
    path = request.args.get("path")
    if not path:
        abort(400)
    date_from_str = request.args.get("date_from", "")
    date_to_str = request.args.get("date_to", "")
    date_from_ts, date_to_ts, date_error = _parse_date_range(date_from_str, date_to_str)

    count, total_bytes, error = 0, 0, date_error
    if not date_error:
        try:
            def _count(sftp):
                c, b = 0, 0
                for info in remote_client.list_files(sftp, path):
                    if date_from_ts is not None and info["mtime"] < date_from_ts:
                        continue
                    if date_to_ts is not None and info["mtime"] > date_to_ts:
                        continue
                    c += 1
                    b += info["size"]
                return c, b
            count, total_bytes = _sftp_call(_count)
        except Exception as e:
            error = str(e)

    return render_template_string(
        ARCHIVE_CONFIRM_TEMPLATE, path=path, count=count, total_bytes=total_bytes,
        date_from=date_from_str, date_to=date_to_str, error=error,
        archive_root=CONFIG["archive_root"],
    )


@app.route("/archive", methods=["POST"])
def do_archive():
    path = request.form.get("path")
    if not path:
        abort(400)
    date_from_str = request.form.get("date_from", "")
    date_to_str = request.form.get("date_to", "")
    date_from_ts, date_to_ts, date_error = _parse_date_range(date_from_str, date_to_str)

    sync_root = CONFIG["sync_root"]
    rel = path[len(sync_root):].lstrip("/") if path.startswith(sync_root) else Path(path).name
    dest_root = f"{CONFIG['archive_root']}/{rel}" if rel else CONFIG["archive_root"]

    summary, error = None, date_error
    if not date_error:
        try:
            summary = _sftp_call(lambda sftp: remote_client.move_tree(
                sftp, path, dest_root,
                min_age_seconds=CONFIG["archive_min_age_seconds"],
                date_from=date_from_ts, date_to=date_to_ts,
            ))
        except Exception as e:
            error = str(e)

    return render_template_string(ARCHIVE_RESULT_TEMPLATE, path=path, dest=dest_root, summary=summary, error=error)


@app.route("/archive/events/scan", methods=["POST"])
def archive_events_scan():
    path = request.form.get("path")
    if not path:
        abort(400)
    date_from_str = request.form.get("date_from", "")
    date_to_str = request.form.get("date_to", "")
    date_from_ts, date_to_ts, date_error = _parse_date_range(date_from_str, date_to_str)
    if date_error:
        abort(400, date_error)

    with EVENT_SCAN_LOCK:
        if EVENT_SCAN_STATE["running"]:
            return redirect(url_for("archive_events_scan_status"))
        now = time.time()
        EVENT_SCAN_STATE.update({
            "running": True, "stage": "starting", "done": 0, "total": 0, "error": None,
            "stage_started_at": now, "stage_baseline_done": 0, "root": path,
        })

    def progress_cb(stage, done, total):
        if EVENT_SCAN_STATE.get("stage") != stage:
            EVENT_SCAN_STATE["stage_started_at"] = time.time()
            EVENT_SCAN_STATE["stage_baseline_done"] = done
        EVENT_SCAN_STATE.update({"stage": stage, "done": done, "total": total})

    def worker():
        try:
            result = scan_events(
                path, CONFIG["out_dir"],
                host=CONFIG["host"], port=CONFIG["port"], username=CONFIG["username"],
                key_filename=CONFIG["key_filename"], password=CONFIG["password"],
                date_from=date_from_ts, date_to=date_to_ts,
                workers=CONFIG["workers"], max_seconds=None,
                progress_cb=progress_cb,
            )
            if result["status"] == "complete":
                _save_event_scan_result({
                    "root": path, "images": result["images"], "others": result["others"],
                })
            EVENT_SCAN_STATE["stage"] = "done"
        except Exception as e:
            EVENT_SCAN_STATE["error"] = str(e)
        finally:
            EVENT_SCAN_STATE["running"] = False

    threading.Thread(target=worker, daemon=True).start()
    return redirect(url_for("archive_events_scan_status"))


@app.route("/archive/events/scan/status")
def archive_events_scan_status():
    if not EVENT_SCAN_STATE["running"] and EVENT_SCAN_STATE["stage"] == "done" and not EVENT_SCAN_STATE["error"]:
        return redirect(url_for("archive_events_review"))

    now = time.time()
    stage_started_at = EVENT_SCAN_STATE.get("stage_started_at") or now
    stage_elapsed = now - stage_started_at
    done, total = EVENT_SCAN_STATE["done"], EVENT_SCAN_STATE["total"]
    baseline = EVENT_SCAN_STATE.get("stage_baseline_done", 0)
    progressed = max(done - baseline, 0)
    eta = None
    if progressed > 0 and total > done:
        rate = stage_elapsed / progressed
        eta = _fmt_duration(rate * (total - done))

    return render_template_string(
        STATUS_TEMPLATE, state=EVENT_SCAN_STATE, scan_root=EVENT_SCAN_STATE.get("root"),
        elapsed=_fmt_duration(stage_elapsed), eta=eta,
    )


@app.route("/archive/events/review")
def archive_events_review():
    if EVENT_SCAN_STATE["running"]:
        return redirect(url_for("archive_events_scan_status"))
    scan_result = _load_event_scan_result()
    if not scan_result:
        return redirect(url_for("archive_browse"))

    out_dir = Path(CONFIG["out_dir"])
    ts_cache = {}
    if (out_dir / "event_ts_cache.json").exists():
        with open(out_dir / "event_ts_cache.json", encoding="utf-8") as f:
            ts_cache = json.load(f)
    thumb_cache = {}
    if (out_dir / "event_thumb_cache.json").exists():
        with open(out_dir / "event_thumb_cache.json", encoding="utf-8") as f:
            thumb_cache = json.load(f)

    files = []
    for path in scan_result["images"]:
        e = ts_cache.get(path)
        if not e:
            continue  # scan didn't finish caching this one -- shouldn't happen once "complete"
        files.append({
            "path": path, "name": path.rsplit("/", 1)[-1], "ts": e["ts"],
            "thumb": thumb_cache.get(path) or "", "is_image": True,
        })
    for o in scan_result["others"]:
        files.append({
            "path": o["path"], "name": o["path"].rsplit("/", 1)[-1],
            "ts": datetime.fromtimestamp(o["mtime"]).isoformat(), "thumb": "", "is_image": False,
        })

    files_json_str = json.dumps(files).replace("</", "<\\/")
    html = EVENT_REVIEW_TEMPLATE.replace("__FILES_JSON__", files_json_str)
    html = html.replace("__ARCHIVE_ROOT_JSON__", json.dumps(CONFIG["archive_root"]))
    html = html.replace("__GAP_HOURS__", str(EVENT_GAP_SECONDS // 3600))
    html = html.replace("__SCAN_ROOT__", str(escape(scan_result["root"])))
    return html


@app.route("/archive/events/confirm", methods=["POST"])
def archive_events_confirm():
    data = request.get_json(force=True, silent=True) or {}
    events = [e for e in (data.get("events") or []) if e.get("paths")]
    if not events:
        return jsonify({"error": "No events to move."}), 400

    try:
        summaries = _sftp_call(lambda sftp: remote_client.move_grouped(
            sftp, events, CONFIG["archive_root"],
            min_age_seconds=CONFIG["archive_min_age_seconds"],
        ))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

    # Drop the scan result so a stale review page/back-button can't be
    # resubmitted against files that have already moved.
    try:
        _event_scan_result_file().unlink()
    except FileNotFoundError:
        pass

    return jsonify({"summaries": summaries})


@app.route("/purge/browse")
def purge_browse():
    return _trash_browse("purge")


@app.route("/restore/browse")
def restore_browse():
    return _trash_browse("restore")


def _trash_browse(mode):
    path = request.args.get("path", CONFIG["start_path"])
    path = posixpath.normpath(path)
    try:
        subdirs = _sftp_call(lambda sftp: remote_client.list_subdirs(sftp, path))
        error = None
    except Exception as e:
        subdirs = []
        error = str(e)
    parent = posixpath.dirname(path.rstrip("/")) or "/"
    return render_template_string(TRASH_BROWSE_TEMPLATE, mode=mode, path=path, subdirs=subdirs, parent=parent, error=error)


@app.route("/purge/confirm")
def purge_confirm():
    return _trash_confirm("purge")


@app.route("/restore/confirm")
def restore_confirm():
    return _trash_confirm("restore")


def _trash_confirm(mode):
    path = request.args.get("path")
    if not path:
        abort(400)
    try:
        summary = _ssh_call(lambda client: remote_client.count_trash(client, path))
        error = None
    except Exception as e:
        summary, error = None, str(e)
    return render_template_string(TRASH_CONFIRM_TEMPLATE, mode=mode, path=path, summary=summary, error=error)


@app.route("/purge", methods=["POST"])
def do_purge():
    path = request.form.get("path")
    if not path:
        abort(400)
    try:
        summary = _ssh_call(lambda client: remote_client.purge_trash(client, path))
        error = None
    except Exception as e:
        summary, error = None, str(e)
    if summary and not error:
        try:
            _reconcile_deleted_cache(path)
        except Exception:
            pass  # best-effort cache cleanup -- the purge itself already succeeded
    return render_template_string(TRASH_RESULT_TEMPLATE, mode="purge", path=path, summary=summary, error=error)


@app.route("/restore", methods=["POST"])
def do_restore():
    path = request.form.get("path")
    if not path:
        abort(400)
    try:
        summary = _remote_call(lambda sftp, client: remote_client.restore_trash(client, sftp, path))
        error = None
    except Exception as e:
        summary, error = None, str(e)
    if summary and not error:
        try:
            _reconcile_deleted_cache(path)
        except Exception:
            pass  # best-effort cache cleanup -- the restore itself already succeeded
    return render_template_string(TRASH_RESULT_TEMPLATE, mode="restore", path=path, summary=summary, error=error)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", type=str, required=True, help="Netbook hostname/IP")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--username", type=str, default="netbook",
                     help="SSH username on the remote machine (default: netbook)")
    ap.add_argument("--key-filename", type=str, default=DEFAULT_KEY_FILENAME,
                     help="Path to a private key file (key-based auth preferred). "
                          f"Default: {DEFAULT_KEY_FILENAME}")
    ap.add_argument("--password", type=str, default=None,
                     help="Fallback password auth if no key is set up")
    ap.add_argument("--out-dir", type=str, required=True, help="Where to write/read cache files")
    ap.add_argument("--start-path", type=str, default="/media/backup",
                     help="Default folder /browse opens on (default /media/backup)")
    ap.add_argument("--time-window", type=int, default=scan_remote.TIME_WINDOW)
    ap.add_argument("--hash-distance", type=int, default=scan_remote.HASH_DISTANCE)
    ap.add_argument("--workers", type=int, default=4,
                     help="Thread pool size for scanning (default 4 -- keep low, see scan_remote.py docstring)")
    ap.add_argument("--http-host", type=str, default="0.0.0.0",
                     help="Interface to bind the local Flask server to (default 0.0.0.0, "
                          "i.e. reachable from other devices on the LAN, not just this PC)")
    ap.add_argument("--http-port", type=int, default=5036, help="Local port to serve on (default 5036)")
    ap.add_argument("--sync-root", type=str, default="/media/backup/sync_data",
                     help="Live-synced root that archive mode's /archive/browse is rooted at "
                          "(default /media/backup/sync_data)")
    ap.add_argument("--archive-root", type=str, default="/media/backup/archive",
                     help="Stable, sync-untouched destination for archive mode "
                          "(default /media/backup/archive)")
    ap.add_argument("--archive-min-age-seconds", type=float, default=300,
                     help="Skip archiving files modified more recently than this "
                          "(still-syncing guard, default 300)")
    args = ap.parse_args()

    CONFIG.update({
        "host": args.host, "port": args.port, "username": args.username,
        "key_filename": args.key_filename, "password": args.password,
        "out_dir": args.out_dir, "start_path": args.start_path,
        "time_window": args.time_window, "hash_distance": args.hash_distance,
        "workers": args.workers,
        "sync_root": args.sync_root, "archive_root": args.archive_root,
        "archive_min_age_seconds": args.archive_min_age_seconds,
    })
    Path(args.out_dir).mkdir(parents=True, exist_ok=True)

    if args.http_host == "0.0.0.0":
        print(f"Serving on http://127.0.0.1:{args.http_port}/ (also reachable from other "
              f"devices on the LAN via this PC's IP) (Ctrl+C to stop)")
    else:
        print(f"Serving on http://{args.http_host}:{args.http_port}/ (Ctrl+C to stop)")
    app.run(host=args.http_host, port=args.http_port, threaded=True)


if __name__ == "__main__":
    main()
