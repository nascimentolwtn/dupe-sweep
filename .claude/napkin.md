# Napkin Runbook

## Curation Rules
- Re-prioritize on every read.
- Keep recurring, high-value notes only.
- Max 10 items per category.

## Current Blocker: Isolate + Platform Channels

**Issue**: Photo scanning runs in a Dart isolate (via `compute()`) to avoid blocking UI, but isolates can't access platform channels without proper initialization. PhotoManager requires platform channel access.
- `BackgroundIsolateBinaryMessenger.ensureInitialized()` requires `ServicesBinding.rootIsolateToken` which is null in background isolate
- Error: "The BackgroundIsolateBinaryMessenger.instance value is invalid..."
- Result: 0 photos found, no scan happens

**Options to fix**:
1. **Remove isolate**: Run scan on main thread (simpler, but slower for large libraries—not ideal)
2. **Defer hash computation**: Scan metadata in isolate, compute hashes on main thread after
3. **Find proper isolate init**: Research photo_manager's isolate support

**Recommended**: Option 2 - scan gets metadata fast, hash computation happens on main thread progressively

---

## Feature Development Pipeline (Priority Order)

### 1. Hash-Based Grouping Integration (IN PROGRESS - BLOCKED)
Integrate dHash (already computed in SimilarityService) into the review UI.
- **Status**: Implemented hash computation + sub-grouping logic, **BLOCKED on isolate issue**
- **What works**: Hash computation code, grouping by Hamming distance (tested in unit tests)
- **What's broken**: Scanning returns 0 photos due to isolate platform channel access

### 2. Scoring UI Integration
Auto-select "best" photo in each group based on sharpness + exposure scoring.
- **Impact**: Reduces manual selection burden for bursts
- **Status**: ScoringService computes scores but review screen ignores them
- **Effort**: Low—add `isBest` flag to PhotoItem, update UI to highlight/preselect, respect scoring in delete workflow

### 3. Settings Screen
Expose configurable time window (default 120s) and Hamming distance threshold (default 10).
- **Impact**: Lets power users fine-tune grouping behavior
- **Effort**: Medium—add new screen, wire to state management, persist to SharedPreferences

### 4. Performance: Lazy Thumbnail Loading
Implement paginated/lazy thumbnail loading on review screen.
- **Impact**: Faster initial render for large groups
- **Watch for**: Current implementation loads all thumbnails at once—may freeze on 50+ photo groups
- **Effort**: Medium

### 5. UI Polish (Lower Priority)
- Dark mode
- Better styling / Material 3 refinement
- Animations (card expand/collapse, delete confirmation)

### 6. Advanced Features (Phase 2+, Do Not Start Yet)
- Re-scan flow (merge with previous results)
- WhatsApp media scoping
- Blurry photo detector
- Cache/junk cleaner
- Large-file finder
- iOS support (untested)

## Constraints & Gotchas

**No Cloud**: This is a personal tool. Never add analytics, telemetry, or cloud sync.
**Explicit Deletion**: Every delete requires user confirmation + OS dialog. No silent deletes.
**Android First**: iOS support is aspirational but untested. Do not spend time on it yet.
**Scoped Storage**: Large-file finder needs MANAGE_EXTERNAL_STORAGE permission (only viable for sideloaded apps, not Play Store).

## Git & Commits

Commit style: "Title + 1-2 lines, no trailers"
Never auto-commit. Wait for user command before committing.
