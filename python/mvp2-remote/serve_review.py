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
from datetime import datetime, timedelta
from pathlib import Path

import imagehash
import paramiko
from flask import Flask, Response, abort, jsonify, redirect, render_template_string, request, url_for

import remote_client
import scan_remote
from scan_remote import cluster_by_time, run_scan, split_by_similarity

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
SCAN_STATE = {"running": False, "stage": None, "done": 0, "total": 0, "error": None}

_client_lock = threading.Lock()
_ssh_client = None
_sftp_client = None


def _get_sftp():
    global _ssh_client, _sftp_client
    with _client_lock:
        if _sftp_client is None:
            _ssh_client = remote_client.connect(
                CONFIG["host"], CONFIG["port"], CONFIG["username"],
                CONFIG["key_filename"], CONFIG["password"],
            )
            _sftp_client = _ssh_client.open_sftp()
        return _sftp_client


def _sftp_call(fn):
    """Call fn(sftp) against the shared connection; on a transport error
    (netbook napped, connection dropped), reconnect once and retry."""
    global _ssh_client, _sftp_client
    try:
        return fn(_get_sftp())
    except (IOError, EOFError, paramiko.SSHException):
        with _client_lock:
            _sftp_client = None
            _ssh_client = None
        return fn(_get_sftp())


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


BROWSE_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Browse netbook folders</title>
<style>
  body { font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background: #f4f5f7; color: #1d1f24; }
  header { background: #1d1f24; color: #fff; padding: 14px 20px; display: flex; align-items: center; gap: 16px; }
  header h1 { font-size: 16px; margin: 0; }
  header a.nav-link { color: #93c5fd; font-size: 13px; text-decoration: none; margin-left: auto; }
  header a.nav-link:hover { text-decoration: underline; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  .breadcrumb { font-size: 13px; color: #666; margin-bottom: 16px; word-break: break-all; }
  ul { list-style: none; padding: 0; }
  li { margin-bottom: 6px; }
  a { color: #3b82f6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .scan-btn { margin-top: 20px; }
  .scan-btn button { background: #3b82f6; color: #fff; border: none; padding: 10px 16px;
                      border-radius: 6px; font-size: 14px; cursor: pointer; }
  .scan-btn button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
</style></head>
<body>
<header><h1>Browse netbook folders</h1><a class="nav-link" href="{{ url_for('archive_browse') }}">Archive mode &rarr;</a></header>
<main>
  <div class="breadcrumb">{{ path }}</div>
  {% if error %}<div class="error">Could not list this folder: {{ error }}</div>{% endif %}
  <ul>
    {% if path != '/' %}<li><a href="{{ url_for('browse', path=parent) }}">.. (up)</a></li>{% endif %}
    {% for d in subdirs %}
      <li><a href="{{ url_for('browse', path=(path.rstrip('/') + '/' + d)) }}">{{ d }}/</a></li>
    {% endfor %}
  </ul>
  <form class="scan-btn" method="post" action="{{ url_for('scan') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit">Scan this folder (and all subfolders)</button>
  </form>
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
  .stage { font-size: 20px; margin-bottom: 10px; text-transform: capitalize; }
  .count { font-size: 14px; color: #aaa; }
  .error { color: #f87171; margin-top: 16px; max-width: 80vw; word-break: break-all; }
</style></head>
<body><div class="box">
  <div class="stage">{{ state.stage or 'starting' }}&hellip;</div>
  <div class="count">{{ state.done }}/{{ state.total }}</div>
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
  header a.nav-link { color: #93c5fd; font-size: 13px; text-decoration: none; margin-left: auto; }
  header a.nav-link:hover { text-decoration: underline; }
  main { padding: 20px; max-width: 800px; margin: 0 auto; }
  .breadcrumb { font-size: 13px; color: #666; margin-bottom: 16px; word-break: break-all; }
  ul { list-style: none; padding: 0; }
  li { margin-bottom: 6px; }
  a { color: #3b82f6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .scan-btn { margin-top: 20px; }
  .scan-btn button { background: #3b82f6; color: #fff; border: none; padding: 10px 16px;
                      border-radius: 6px; font-size: 14px; cursor: pointer; }
  .scan-btn button:hover { filter: brightness(1.1); }
  .error { color: #ef4444; margin-bottom: 16px; }
</style></head>
<body>
<header><h1>Archive netbook folders</h1><a class="nav-link" href="{{ url_for('browse') }}">Dedup scan mode &rarr;</a></header>
<main>
  <div class="breadcrumb">{{ path }}</div>
  <p style="font-size:13px;color:#666">Moving a folder here relocates it (same-disk, instant) from
    <code>{{ sync_root }}</code> into <code>{{ archive_root }}</code>, out of the way of the live sync
    client, so it's safe to delete the phone-side originals afterwards.</p>
  {% if error %}<div class="error">Could not list this folder: {{ error }}</div>{% endif %}
  <ul>
    {% if can_go_up %}<li><a href="{{ url_for('archive_browse', path=parent) }}">.. (up)</a></li>{% endif %}
    {% for d in subdirs %}
      <li><a href="{{ url_for('archive_browse', path=(path.rstrip('/') + '/' + d)) }}">{{ d }}/</a></li>
    {% endfor %}
  </ul>
  <form class="scan-btn" method="get" action="{{ url_for('archive_confirm') }}">
    <input type="hidden" name="path" value="{{ path }}">
    <button type="submit">Archive this folder (and all subfolders)</button>
  </form>
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
    <button type="submit" formaction="{{ url_for('do_archive') }}" formmethod="post" class="danger">Confirm: move these files to archive</button>
  </form>
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
  .photo-card img { width: 100%; height: 190px; object-fit: cover; border-radius: 6px; display: block; background: #eee; cursor: zoom-in; }
  .badge { position: absolute; top: 10px; left: 10px; background: #22c55e; color: #fff; font-size: 11px;
           padding: 2px 7px; border-radius: 999px; font-weight: 600; }
  .badge.deleted { background: #ef4444; left: auto; right: 10px; }
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
</style>
</head>
<body>
<header>
  <h1>Duplicate photo review (remote)</h1>
  <span class="stat" id="stat-summary">-</span>
  <button id="reset-btn">Reset to AI picks</button>
  <button id="clear-btn" class="secondary">Unmark all (keep everything)</button>
  <button id="hide-reviewed-btn" class="secondary">Hide reviewed groups</button>
  <button id="save-progress-btn" class="secondary">Save progress</button>
  <button id="load-progress-btn" class="secondary">Load progress</button>
  <input type="file" id="load-progress-input" accept="application/json" style="display:none">
  <button id="delete-btn" class="danger">Delete marked</button>
  <a href="/archive/browse" style="color:#93c5fd;font-size:13px;text-decoration:none;margin-left:auto">Archive mode &rarr;</a>
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
    header.innerHTML = `<span class="title">Group ${gi+1} — ${g.ts}</span>
      <span class="meta">${g.items.length} photos</span>
      <label class="reviewed-toggle">
        <input type="checkbox" class="reviewed-cb" data-group="${gi}" ${g.reviewed ? "checked" : ""}>
        Reviewed
      </label>`;
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
      card.innerHTML = `
        ${ii === 0 ? '<span class="badge">BEST</span>' : ""}
        ${it.already_deleted ? '<span class="badge deleted">DELETED</span>' : ""}
        <img src="data:image/jpeg;base64,${it.thumb || ""}" loading="lazy">
        <div class="photo-meta">${it.name}<br>${it.ts}<br>${(it.size_kb/1024).toFixed(1)} MB, score ${it.score.toFixed(0)}</div>
        ${checkboxHtml}`;
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


def _build_groups(hash_cache, score_cache, thumb_cache, deleted, time_window, hash_distance):
    items = []
    for path, e in hash_cache.items():
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
        SCAN_STATE.update({"running": True, "stage": "starting", "done": 0, "total": 0, "error": None})

    def progress_cb(stage, done, total):
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
            SCAN_STATE["stage"] = "done"
        except Exception as e:
            SCAN_STATE["error"] = str(e)
        finally:
            SCAN_STATE["running"] = False

    threading.Thread(target=worker, daemon=True).start()
    return redirect(url_for("scan_status"))


@app.route("/scan/status")
def scan_status():
    if not SCAN_STATE["running"] and SCAN_STATE["stage"] == "done" and not SCAN_STATE["error"]:
        return redirect(url_for("review"))
    return render_template_string(STATUS_TEMPLATE, state=SCAN_STATE)


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

    groups_json = _build_groups(
        hash_cache, score_cache, thumb_cache, deleted,
        CONFIG["time_window"], CONFIG["hash_distance"],
    )

    # Escape "</" so a base64 thumbnail can never accidentally contain a
    # literal "</script>" and truncate the inline script block.
    groups_json_str = json.dumps(groups_json).replace("</", "<\\/")
    html = HTML_TEMPLATE.replace("__GROUPS_JSON__", groups_json_str)
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
    ap.add_argument("--http-port", type=int, default=5000, help="Local port to serve on (default 5000)")
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

    print(f"Serving on http://127.0.0.1:{args.http_port}/ (Ctrl+C to stop)")
    app.run(host="127.0.0.1", port=args.http_port, threaded=True)


if __name__ == "__main__":
    main()
