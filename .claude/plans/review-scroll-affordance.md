# Plan: Add a touchable/draggable scrollbar to the Duplicate Review screen

## Bug

On a real device, the duplicate-review list (`DuplicateReviewScreen`) is hard to
scroll when there are many groups (e.g. hundreds of groups from a ~7,000-photo
library). The list currently relies on flick/inertial scrolling only — there is
no visible, always-present, drag-able scrollbar thumb on the right edge.

## Root cause (verified)

`E:\dev\dupe-sweep\lib\screens\duplicate_review_screen.dart`, lines 49–58:

```dart
return Stack(
  children: [
    ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: provider.photoGroups.length,
      itemBuilder: (context, index) {
        final group = provider.photoGroups[index];
        return PhotoGroupCard(group: group);
      },
    ),
    Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SummaryBar(
        groups: provider.photoGroups,
      ),
    ),
  ],
);
```

The `ListView.builder` is not wrapped in a `Scrollbar` widget and has no
attached `ScrollController`. Android's default scrollbar (a thin fading
indicator) may flash briefly during a scroll gesture but is not a stable touch
target and is not draggable by design — it's just glanceable feedback.

## Environment facts (checked, so the implementer doesn't have to re-derive them)

- `pubspec.yaml` (`E:\dev\dupe-sweep\pubspec.yaml`): `environment: sdk: '>=3.0.0 <4.0.0'`.
- Installed Flutter SDK in this dev environment: **Flutter 3.44.9 (stable),
  Dart 3.12.2** (via `flutter --version`). This is well past the versions that
  introduced `Scrollbar.thumbVisibility` (replaced the deprecated
  `isAlwaysShown` in Flutter 3.4), `Scrollbar.trackVisibility` (Flutter 3.7+),
  and `Scrollbar.interactive` (stable since Flutter 2.5). All three properties
  used in this plan are safe to use.
- `E:\dev\dupe-sweep\lib\main.dart` line 26: `useMaterial3: true` is set on
  the app's `ThemeData`. `trackVisibility` only paints a visible track when
  Material 3 is active, so the track will actually render, not just the thumb.
- Decision: use an **explicit `ScrollController`** attached directly to the
  `ListView.builder` and passed to the `Scrollbar`, rather than relying on
  `PrimaryScrollController` auto-attachment. This is the safer, more
  explicit, more widely-portable approach and avoids any ambiguity about
  whether the `ListView` is the "primary" scrollable in this route (it also
  makes intent obvious to future readers of the file).

## Scope

Single file change: `E:\dev\dupe-sweep\lib\screens\duplicate_review_screen.dart`.
No other files need code changes. (`photo_group_card.dart` and
`summary_bar.dart` were read only to confirm they don't block this fix — see
"Considerations" below.)

No custom fast-scroll/index/letter-jump widget, no third-party scrollbar
package. Flutter's built-in `Scrollbar` widget is sufficient per the actual
request ("show a scroll bar on the right to touch and swipe").

## Implementation steps

1. **Convert the screen's state class to own a `ScrollController`.**
   In `E:\dev\dupe-sweep\lib\screens\duplicate_review_screen.dart`, inside
   `_DuplicateReviewScreenState` (starts at line 15), add a field and
   lifecycle methods:

   ```dart
   class _DuplicateReviewScreenState extends State<DuplicateReviewScreen> {
     final ScrollController _scrollController = ScrollController();

     @override
     void dispose() {
       _scrollController.dispose();
       super.dispose();
     }

     @override
     Widget build(BuildContext context) {
       ...
   ```

   (Place the field and `dispose()` override before the existing `build`
   method.)

2. **Wrap the `ListView.builder` in a `Scrollbar` and attach the controller
   to both.** Replace lines 49–58 (the `Stack`'s first child, the bare
   `ListView.builder`) with:

   ```dart
   return Stack(
     children: [
       Scrollbar(
         controller: _scrollController,
         thumbVisibility: true,
         trackVisibility: true,
         interactive: true,
         child: ListView.builder(
           controller: _scrollController,
           padding: const EdgeInsets.only(bottom: 100),
           itemCount: provider.photoGroups.length,
           itemBuilder: (context, index) {
             final group = provider.photoGroups[index];
             return PhotoGroupCard(group: group);
           },
         ),
       ),
       Positioned(
         bottom: 0,
         left: 0,
         right: 0,
         child: SummaryBar(
           groups: provider.photoGroups,
         ),
       ),
     ],
   );
   ```

   Key points for the implementer:
   - `controller: _scrollController` must be set on **both** the `Scrollbar`
     and the `ListView.builder` — a `Scrollbar` needs an explicit
     `ScrollController` that is *also* attached to exactly one `Scrollable`
     descendant, or it will assert/fail to find a position at runtime.
   - `thumbVisibility: true` keeps the thumb always visible (not just during
     scroll), so the user can find and grab it without first flicking the
     list.
   - `trackVisibility: true` draws the background track (Material 3 only —
     already satisfied per the environment facts above), giving a clear
     visual affordance that the thumb is draggable.
   - `interactive: true` makes the thumb draggable with a finger (this is
     Flutter's default already on most platforms, but set it explicitly so
     the intent is documented and not dependent on platform defaults).
   - The `Scrollbar` widget must wrap only the `ListView.builder`, not the
     whole `Stack` — otherwise it will try to attach to the `Stack`, which
     isn't scrollable.

3. **No changes needed to `photo_group_card.dart`.** Groups are
   variable-height (an expanded card with many near-duplicate photos grows
   taller via the horizontal `SingleChildScrollView` at
   `E:\dev\dupe-sweep\lib\widgets\photo_group_card.dart` lines 80–88). This
   does not block using `Scrollbar` on a `ListView.builder`: Flutter's
   `Scrollbar` estimates thumb size/position from `ScrollMetrics`
   (`maxScrollExtent` / `viewportDimension`), which already account for
   actual rendered extents as items are laid out. The thumb size is an
   approximation (not a mathematically exact "12% of items visible"
   guarantee when heights vary a lot), but this is standard, expected
   `Scrollbar` behavior and is not worth engineering around for this app.

4. **Considerations already checked — no action required, but flagged for
   awareness:**
   - `E:\dev\dupe-sweep\lib\widgets\summary_bar.dart` — its `Container` has
     `padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)` plus a
     `Row` of buttons (~36–40px tall) and, when photos are selected, an
     extra `Text` + `SizedBox(height: 12)` above the row. Total height is
     roughly 60–110px depending on whether the "Delete N photos?" line is
     showing. The existing `padding: EdgeInsets.only(bottom: 100)` on the
     `ListView.builder` (line 52, unchanged by this fix) was already sized
     to clear this, so list *content* does not visually collide with the
     `SummaryBar`. No padding change is needed for that.
   - However, because the `ListView` is a direct `Stack` child (not
     constrained by a `Column` + `Expanded` layout), its scrollable
     viewport — and therefore the `Scrollbar`'s track/thumb — spans the
     **full height of the screen body**, including the ~100px strip behind
     the `SummaryBar`. Since `SummaryBar` is painted on top in the `Stack`
     and is opaque, if the thumb happens to scroll into that bottom strip
     (e.g., when the user is near the end of a long list), the `SummaryBar`
     may visually and physically sit on top of the thumb in that band,
     making it briefly harder to grab right at the bottom.
   - This is a minor edge case, not a blocker, and matches the scope of the
     user's request (a general "show a scrollbar" fix, not "make it perfect
     in max-selection state"). Do not restructure the layout for this pass.
     If, after manual testing, this overlap turns out to be a real usability
     problem, the follow-up fix would be to change the outer `Stack` +
     `Positioned` layout to a `Column` with `Expanded(child: Scrollbar(...))`
     and `SummaryBar` as a normal trailing sibling (removing the need for
     `bottom: 100` padding entirely) — but that is a larger structural change
     and out of scope unless the simple fix proves insufficient.

## Verification

1. **Static/compile check (agent-verifiable):**
   ```bash
   flutter analyze
   ```
   Run from `E:\dev\dupe-sweep`. Should report no new errors/warnings
   introduced by this change (pre-existing warnings, if any, are out of
   scope).

2. **Format check (agent-verifiable):**
   ```bash
   dart format lib/screens/duplicate_review_screen.dart
   ```
   Confirm it's a no-op or apply the formatting.

3. **Build sanity (agent-verifiable):** the change only touches one file and
   uses stable, well-known `Scrollbar`/`ScrollController` APIs available in
   the installed Flutter 3.44.9 SDK, so `flutter analyze` passing is
   sufficient evidence it compiles. A full `flutter build apk`/`flutter run`
   is optional but can be done if available.

4. **Manual visual/touch verification (NOT agent-verifiable — flag for the
   user):** An automated agent can confirm the code compiles and the widget
   tree is structurally correct, but cannot confirm the scrollbar *feels*
   right on a touchscreen. The user should manually check on a real device
   or emulator, ideally with a library large enough to produce many groups
   (per the bug report, ~7,000 photos / hundreds of groups is the target
   scenario; a scan producing at least a few dozen groups should be enough to
   exceed one screen and show a scrollbar worth testing):
   - The scrollbar thumb and track are visible on the right edge immediately
     on screen load (not just during a scroll gesture), because
     `thumbVisibility`/`trackVisibility` are `true`.
   - Dragging the thumb with a finger scrolls the list, including scrolling
     to the very top and very bottom.
   - The thumb doesn't feel "stuck" or hard to grab near the bottom of the
     screen (this is the `SummaryBar` overlap edge case noted in step 4 of
     the implementation section above — confirm whether it's actually
     noticeable in practice).
   - Expanding a group with many photos (which grows that card's height) does
     not cause the scrollbar thumb to behave erratically (jump size changes
     abruptly, etc.) — some size adjustment on relayout is expected and fine,
     it just shouldn't glitch/flicker.

## Summary of the diff shape

- 1 file changed: `lib/screens/duplicate_review_screen.dart`.
- Add: `ScrollController` field + `dispose()` override in
  `_DuplicateReviewScreenState`.
- Wrap: the existing `ListView.builder` (currently the first child of the
  `Stack`, lines 51–58) in a `Scrollbar(controller: ..., thumbVisibility:
  true, trackVisibility: true, interactive: true, child: ListView.builder(
  controller: ..., ...))`.
- No other files change.
