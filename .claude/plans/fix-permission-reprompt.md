# Fix: Permission screen re-prompts on every launch

## Bug

`PermissionScreen` ("Grant Photo Access") is shown on every app launch, even
after the user already granted photo access in a previous session. The user
has to look at the full onboarding UI and re-tap the button every time,
instead of the app skipping straight to scanning when permission is already
granted.

## Confirmed root cause

### `E:\dev\dupe-sweep\lib\main.dart`

- Line 28: `home: const PermissionScreen(),` — the app's `MaterialApp.home` is
  unconditionally `PermissionScreen`, on every cold start, with no check of
  prior permission state. This is expected/fine as the initial route; the
  actual bug is that `PermissionScreen` itself doesn't skip past its own UI
  when it discovers permission is already granted.

### `E:\dev\dupe-sweep\lib\screens\permission_screen.dart`

- Line 13: `bool _hasPermission = false;` — field is written in
  `_checkPermission()` (line 24) and in `_requestPermission()` (line 31), but
  is **never read anywhere in `build()`** (lines 56–107). It is dead state
  today — confirmed by inspection, `_hasPermission` does not appear anywhere
  in the `build` method or elsewhere in the file. So conditionally rendering
  based on `_hasPermission` would be a UI-only fix; the correct fix is
  behavioral navigation, matching the pattern already used elsewhere in this
  file.
- Lines 21–26 (`_checkPermission`), run from `initState()` at line 18:
  ```dart
  Future<void> _checkPermission() async {
    final status = await Permission.photos.status;
    setState(() {
      _hasPermission = status.isGranted;
    });
  }
  ```
  This checks status but never navigates, regardless of the result.
- Lines 28–53 (`_requestPermission`) **does** navigate away on success, and
  is the pattern to mirror:
  ```dart
  Future<void> _requestPermission() async {
    final status = await Permission.photos.request();
    setState(() {
      _hasPermission = status.isGranted;
    });

    if (status.isGranted) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const ScanProgressScreen(),
          ),
        );
      }
    } else if (status.isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permission denied')),
        );
      }
    } else if (status.isPermanentlyDenied) {
      if (mounted) {
        openAppSettings();
      }
    }
  }
  ```

So the screen already has one code path (`_requestPermission`) that
navigates on success, and one (`_checkPermission`) that silently swallows the
result. The fix is to make `_checkPermission` behave the same way.

## Dependency check (already done — no action needed)

- `pubspec.yaml` line 16: `permission_handler: ^13.0.1`.
- Inspected
  `permission_handler_platform_interface-4.4.0/lib/src/permission_status.dart`
  (the version resolved in this project's pub cache). `PermissionStatus` is
  an enum: `denied`, `granted`, `restricted`, `limited`, `permanentlyDenied`,
  `provisional`. The `limited` value's doc comment says it's relevant "Only
  for Photo Library picker... Only supported on iOS (iOS14+) and Android
  (Android 14+)" — i.e. on Android 14+ (API 34+), if the user picks "Select
  photos..." (partial access) instead of "Allow all", `Permission.photos`
  reports `PermissionStatus.limited`, not `.granted`.
- Decision: treat `status.isGranted || status.isLimited` as "already have
  usable access" in `_checkPermission`, so a user who granted partial/limited
  access on Android 14+ also skips straight to scanning on relaunch instead
  of being stuck on the permission screen forever (since re-tapping "Grant
  Photo Access" for a `limited` status does not necessarily change the OS
  status). Apply the same `isGranted || isLimited` condition to the success
  branch of `_requestPermission` (currently line 34, `if (status.isGranted)`)
  for consistency — otherwise a first-time user who selects limited access
  would fall through to the `else` branches (which don't handle `.limited`
  at all — no branch fires, no navigation, no message) rather than proceeding
  to scan.
- No new dependency, no `pubspec.yaml` change, no `AndroidManifest.xml`
  change. `Permission.photos` continues to be the only permission requested.

## Loading-state UX

`Permission.photos.status` is async, so on every cold start there's a brief
window where the app doesn't yet know whether to show the "Grant Photo
Access" UI or skip it. Without handling this, the full permission UI (icon,
heading, paragraph, button) will flash on screen for a frame or more before
`_checkPermission` resolves and (with the fix) immediately navigates away —
a visible flicker.

**Decision: keep this local to `PermissionScreen`, not in `main.dart` /
`AppStateProvider`.** Rationale:
- `AppStateProvider` (lib/main.dart lines 34–57) currently only tracks scan
  state (`photoGroups`, `isScanning`, `scanProgress`, `scanStatus`) — it has
  no concept of permission state today, and CLAUDE.md's roadmap doesn't call
  for one. Adding a global "checking permission" bootstrap flag would touch
  the shared provider and `main.dart`'s routing for a concern that only ever
  affects one screen's first frame.
- Simpler, lower-risk option: `_checking` as local `State` on
  `PermissionScreen` achieves the same visible result (no flash of the
  wrong UI) with a one-file change. This is the recommended and simplest
  option consistent with CLAUDE.md's guidance to prefer the Provider
  pattern only for state that's actually shared across screens.
- Revisit only if a future screen also needs to know "is permission already
  resolved" before it builds — not the case today.

Implementation: add a private `bool _checking = true;` field to
`_PermissionScreenState`, initialized true. Flip it false (via `setState`)
only in the branch of `_checkPermission` where the screen actually needs to
render (i.e. when permission is NOT already granted/limited — in the
granted/limited case we navigate away instead of setting state, so there is
no extra rebuild/flash of the granted-UI). While `_checking` is true,
`build()` returns a minimal `Scaffold` with a centered
`CircularProgressIndicator` instead of the full onboarding content.

## Exact code change — `E:\dev\dupe-sweep\lib\screens\permission_screen.dart`

1. Add a loading flag next to the existing field (line 13):
   ```dart
   bool _hasPermission = false;
   bool _checking = true;
   ```

2. Replace `_checkPermission()` (current lines 21–26) with:
   ```dart
   Future<void> _checkPermission() async {
     final status = await Permission.photos.status;

     if (status.isGranted || status.isLimited) {
       if (mounted) {
         Navigator.of(context).pushReplacement(
           MaterialPageRoute(
             builder: (_) => const ScanProgressScreen(),
           ),
         );
       }
       return;
     }

     if (mounted) {
       setState(() {
         _hasPermission = status.isGranted;
         _checking = false;
       });
     }
   }
   ```
   Notes:
   - `mounted` check before `Navigator.of(context)` matches the existing
     style used in `_requestPermission` (lines 35, 43, 49).
   - Guard the final `setState` with `mounted` too — `_checkPermission` runs
     from `initState`/an awaited call, and the widget could theoretically be
     disposed before the `await Permission.photos.status` future resolves
     (e.g. rapid navigation in tests). The existing `_requestPermission`
     doesn't guard its first `setState` (line 30) — leave that one as-is to
     keep this change minimal and scoped to the bug; only the new code needs
     the guard.
   - `_hasPermission` remains otherwise unused in `build()`; leaving it
     assigned keeps behavior parity with `_requestPermission` and avoids
     an unrelated cleanup in this bugfix. (Optional follow-up, not part of
     this fix: consider removing `_hasPermission` entirely in a later pass
     since it has no reader — flag for the user, do not do it here to keep
     the diff minimal and focused on the reported bug.)

3. Update `_requestPermission()`'s success condition (current line 34) for
   consistency with the `isLimited` handling above:
   ```dart
   if (status.isGranted || status.isLimited) {
   ```
   Leave the rest of `_requestPermission` (lines 28–53) unchanged.

4. Update `build()` (current lines 55–107) to branch on `_checking`:
   ```dart
   @override
   Widget build(BuildContext context) {
     if (_checking) {
       return const Scaffold(
         body: Center(
           child: CircularProgressIndicator(),
         ),
       );
     }

     return Scaffold(
       // ...existing appBar/body content unchanged...
     );
   }
   ```
   Everything currently inside the returned `Scaffold` (lines 57–106) stays
   exactly as-is; only wrap it with the `_checking` early return.

Net effect:
- Permission already granted/limited on launch → user sees a brief spinner
  (only if the async check hasn't resolved by first frame) then lands
  directly on `ScanProgressScreen`. No "Grant Photo Access" flash.
- Permission not yet granted → spinner resolves to the existing onboarding
  UI, unchanged from today.
- Freshly granted via the button → unchanged existing behavior in
  `_requestPermission`, now also covering `isLimited`.

## `main.dart` — confirm no change needed

`home: const PermissionScreen()` (line 28) stays as-is. `PermissionScreen`
remains the single entry point; it now internally decides (via
`_checkPermission`) whether to render itself or hand off immediately to
`ScanProgressScreen`. No changes to `AppStateProvider` or `MultiProvider`
wiring are required for this fix, consistent with the "keep it local to
PermissionScreen" decision above.

## Out of scope (do not do these as part of this fix)

- Do not change `AndroidManifest.xml` or the permission being requested.
- Do not add new dependencies.
- Do not remove `_hasPermission` (flagged above as an optional later
  cleanup only).
- Do not touch `ScanProgressScreen`, `DuplicateReviewScreen`, or the
  services layer — this is purely a navigation-flow fix in one screen.

## Verification steps for the implementing agent

1. `flutter analyze` from `E:\dev\dupe-sweep` — must be clean (no new
   warnings/errors introduced by the edit).
2. `flutter test` — run the existing suite
   (`E:\dev\dupe-sweep\test\similarity_service_test.dart` and
   `E:\dev\dupe-sweep\test\widget_test.dart`). Neither test file currently
   exercises `PermissionScreen` or the permission flow — grep confirms no
   `PermissionScreen`/`Permission.photos` references in `test/`. Note:
   `test/widget_test.dart` is the unmodified Flutter counter-app template
   (`pumpWidget(const MyApp())`, taps a `+` icon, checks for `'0'`/`'1'`
   text) and does not match this app's actual root widget
   (`DupesweepApp`) or UI at all — it appears to already be broken/stale
   independent of this change. Do not attempt to fix `widget_test.dart` as
   part of this task; just confirm this fix doesn't introduce *new*
   `flutter test` failures beyond that pre-existing one, and mention its
   pre-existing failure state to the user rather than silently leaving it.
3. `dart format lib/screens/permission_screen.dart` (per CLAUDE.md
   formatting convention) after editing.
4. Manual/device verification (cannot be fully automated by an agent —
   flag explicitly for the user to confirm):
   - Fresh install or clear app data, launch app → should see permission
     screen (unchanged baseline behavior).
   - Tap "Grant Photo Access", grant full access → should navigate to scan
     screen (unchanged baseline behavior).
   - Fully close the app (swipe away from recents, not just background) and
     relaunch → **this is the actual bug fix to confirm**: app should go
     straight to the scan screen (briefly, if at all, showing a spinner)
     instead of showing "Grant Photo Access" again.
   - On an Android 14+ device/emulator, choose "Select photos..." (limited
     access) instead of "Allow all", then relaunch → should also skip
     straight to the scan screen given the `isLimited` handling above.
   - Revoke permission via system Settings, relaunch → should correctly
     show the permission screen again (i.e. confirm the fix doesn't
     over-skip when permission is genuinely not granted).
