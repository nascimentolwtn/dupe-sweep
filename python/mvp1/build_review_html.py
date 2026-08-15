#!/usr/bin/env python3
"""
build_review_html.py

Builds a single self-contained HTML file (thumbnails embedded as base64,
no external files, no server needed) to visually review the duplicate
groups found by find_duplicate_photos.py, instead of reviewing bare file
paths in a markdown/CSV report.

Reuses hash_cache.json and score_cache.json produced by that script so it
doesn't need to re-hash or re-score anything. Thumbnail generation is the
new expensive step, so it gets the same threaded + resumable treatment
(thumb_cache.json) since it will likely take more than one run given how
slow the mounted folder is.

Usage:
    python3 build_review_html.py --max-seconds 32 --workers 4
    (re-run the same command until it reports the html file was written)
"""

import argparse
import base64
import io
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageOps
import imagehash

TIME_WINDOW = 120
HASH_DISTANCE = 10
THUMB_MAX_DIM = 280
THUMB_QUALITY = 60

LINUX_PREFIX = "/sessions/beautiful-sleepy-brown/mnt/s21_LW"
WIN_PREFIX = r"E:\temp\_07_Photos_Images\s21_LW"


def to_windows_path(p: str) -> str:
    if p.startswith(LINUX_PREFIX):
        rest = p[len(LINUX_PREFIX):].replace("/", "\\")
        return WIN_PREFIX + rest
    return p


def cluster_by_time(items, window_seconds):
    items = sorted(items, key=lambda x: x["ts"])
    clusters, current = [], []
    for item in items:
        if current and (item["ts"] - current[-1]["ts"]).total_seconds() > window_seconds:
            clusters.append(current)
            current = []
        current.append(item)
    if current:
        clusters.append(current)
    return [c for c in clusters if len(c) > 1]


def split_by_similarity(cluster, hash_distance):
    groups = []
    for item in cluster:
        placed = False
        if item["hash"] is None:
            groups.append([item])
            continue
        for g in groups:
            if g[0]["hash"] is not None and (item["hash"] - g[0]["hash"]) <= hash_distance:
                g.append(item)
                placed = True
                break
        if not placed:
            groups.append([item])
    return [g for g in groups if len(g) > 1]


def make_thumb_b64(path_str: str):
    try:
        with Image.open(path_str) as img:
            img.draft("RGB", (THUMB_MAX_DIM * 2, THUMB_MAX_DIM * 2))
            img = ImageOps.exif_transpose(img)
            img.thumbnail((THUMB_MAX_DIM, THUMB_MAX_DIM), Image.LANCZOS)
            img = img.convert("RGB")
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=THUMB_QUALITY, optimize=True)
            return base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception:
        return None


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Duplicate photo review</title>
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
  .lightbox .lb-meta { color: #eee; font-size: 13px; margin-top: 10px; text-align: center; max-width: 90vw; word-break: break-all; }
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
  <h1>Duplicate photo review</h1>
  <span class="stat" id="stat-summary">-</span>
  <button id="reset-btn">Reset to AI picks</button>
  <button id="clear-btn" class="secondary">Unmark all (keep everything)</button>
  <button id="hide-reviewed-btn" class="secondary">Hide reviewed groups</button>
  <button id="save-progress-btn" class="secondary">Save progress</button>
  <button id="load-progress-btn" class="secondary">Load progress</button>
  <input type="file" id="load-progress-input" accept="application/json" style="display:none">
  <button id="export-btn">Export delete list (CSV)</button>
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
const STATE_KEY = "dupe_review_state_v1";
let hideReviewed = false;

function fmtMB(bytes) { return (bytes / (1024*1024)).toFixed(1) + " MB"; }
function groupKey(g) { return g.items[0].path; }

// Thumbnails are deliberately small (kept the file a manageable size), so
// the lightbox opens the real, full-resolution file straight off disk via
// a file:// URL instead of embedding a second, larger copy of every photo.
function toFileUrl(winPath) {
  const parts = winPath.split("\\\\");
  const drive = parts[0];
  const rest = parts.slice(1).map(p => encodeURIComponent(p));
  return "file:///" + drive + "/" + rest.join("/");
}

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
  img.src = toFileUrl(it.path);
  img.onerror = () => {
    document.getElementById("lb-fallback").textContent =
      "Browser blocked loading the local file directly — copy the path below and open it manually.";
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
// so progress survives closing the tab, switching browsers, or the file
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
document.getElementById("export-btn").addEventListener("click", () => {
  let rows = ["path,size_kb,score,timestamp"];
  GROUPS.forEach(g => g.items.forEach(it => {
    if (it.marked && !it.already_deleted) rows.push(`"${it.path}",${it.size_kb},${it.score.toFixed(1)},${it.ts}`);
  }));
  const blob = new Blob([rows.join("\\n")], {type: "text/csv"});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "delete_list.csv";
  a.click();
});

loadFromLocalStorage();
render();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", type=str, required=True)
    ap.add_argument("--time-window", type=int, default=TIME_WINDOW)
    ap.add_argument("--hash-distance", type=int, default=HASH_DISTANCE)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--max-seconds", type=float, default=None)
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    hash_cache = json.load(open(out_dir / "hash_cache.json", encoding="utf-8"))
    score_cache = json.load(open(out_dir / "score_cache.json", encoding="utf-8"))

    items = []
    for path, e in hash_cache.items():
        items.append({
            "path": path,
            "ts": datetime.fromisoformat(e["ts"]),
            "hash": imagehash.hex_to_hash(e["hash"]) if e["hash"] else None,
            "size": e["size"],
        })

    time_clusters = cluster_by_time(items, args.time_window)
    all_groups = []
    for tc in time_clusters:
        all_groups.extend(split_by_similarity(tc, args.hash_distance))
    print(f"{len(all_groups)} groups, {sum(len(g) for g in all_groups)} photos to thumbnail.")

    for g in all_groups:
        for item in g:
            s = score_cache.get(item["path"], {"sharpness": 0.0, "exposure_penalty": 0.0})
            item["score"] = s["sharpness"] - s["exposure_penalty"]
        g.sort(key=lambda x: x["score"], reverse=True)

    thumb_cache_path = out_dir / "thumb_cache.json"
    thumb_cache = {}
    if thumb_cache_path.exists():
        try:
            thumb_cache = json.load(open(thumb_cache_path, encoding="utf-8"))
        except Exception:
            thumb_cache = {}

    all_paths = sorted({item["path"] for g in all_groups for item in g})
    missing = [p for p in all_paths if p not in thumb_cache]
    print(f"{len(all_paths) - len(missing)}/{len(all_paths)} thumbnails cached, {len(missing)} remaining.")

    if missing:
        start = time.monotonic()
        done_this_run = 0
        executor = ThreadPoolExecutor(max_workers=args.workers)
        futures = {executor.submit(make_thumb_b64, p): p for p in missing}
        try:
            for fut in as_completed(futures):
                p = futures[fut]
                b64 = fut.result()
                thumb_cache[p] = b64
                done_this_run += 1
                if done_this_run % 100 == 0:
                    print(f"  thumbnailed {done_this_run}/{len(missing)} this run "
                          f"({time.monotonic()-start:.0f}s elapsed)")
                    json.dump(thumb_cache, open(thumb_cache_path, "w", encoding="utf-8"))
                if args.max_seconds is not None and (time.monotonic() - start) > args.max_seconds:
                    break
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
        json.dump(thumb_cache, open(thumb_cache_path, "w", encoding="utf-8"))
        print(f"Thumbnailed {done_this_run} this run ({len(thumb_cache)}/{len(all_paths)} total).")

        still_missing = [p for p in all_paths if p not in thumb_cache]
        if still_missing:
            print(f"\n{len(still_missing)} thumbnails still missing. Re-run the same command to continue.")
            sys.stdout.flush()
            os._exit(2)

    def is_already_deleted(path_str: str) -> bool:
        p = Path(path_str)
        if p.exists():
            return False
        # moved by apply_delete_list.py into a sibling _to_delete folder
        return (p.parent / "_to_delete" / p.name).exists()

    groups_json = []
    for g in all_groups:
        items_out = []
        for idx, item in enumerate(g):
            already_deleted = is_already_deleted(item["path"])
            items_out.append({
                "path": to_windows_path(item["path"]),
                "name": Path(item["path"]).name,
                "ts": item["ts"].strftime("%Y-%m-%d %H:%M:%S"),
                "size_kb": round(item["size"] / 1024, 1),
                "score": item["score"],
                "thumb": thumb_cache.get(item["path"]) or "",
                "marked": already_deleted or idx != 0,
                "already_deleted": already_deleted,
            })
        # default a group to "reviewed" if everything non-best in it has
        # already been moved to _to_delete — nothing left to decide there
        reviewed_default = all(it["already_deleted"] for it in items_out[1:]) if len(items_out) > 1 else True
        groups_json.append({
            "ts": g[0]["ts"].strftime("%Y-%m-%d %H:%M:%S"),
            "reviewed": reviewed_default,
            "items": items_out,
        })

    # Escape "</" so a base64 blob can never accidentally contain a literal
    # "</script>" and truncate the inline script block.
    groups_json_str = json.dumps(groups_json).replace("</", "<\\/")
    html = HTML_TEMPLATE.replace("__GROUPS_JSON__", groups_json_str)
    out_path = out_dir / "duplicate_review.html"
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"\nWrote {out_path} ({out_path.stat().st_size/1024/1024:.1f} MB)")


if __name__ == "__main__":
    main()
