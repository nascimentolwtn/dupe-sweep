import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_item.dart';
import '../theme/app_theme.dart';

/// Fullscreen, swipeable photo viewer for comparing the photos within a
/// single group side by side (one at a time) at full resolution --
/// mirrors the lightbox in `python-mvp1/build_review_html.py` (prev/next
/// navigation, a "mark for deletion" checkbox that stays in sync with the
/// grid view, both readable at a glance while zoomed in on detail).
///
/// [photos] is the SAME list (and same [PhotoItem] instances) the calling
/// `PhotoGroupCard` holds, so toggling the checkbox here mutates the shared
/// objects directly -- the card picks up the change via its own `setState`
/// after this screen is popped, no separate sync step needed.
class PhotoFullscreenViewer extends StatefulWidget {
  final List<PhotoItem> photos;
  final int initialIndex;

  const PhotoFullscreenViewer({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  @override
  State<PhotoFullscreenViewer> createState() => _PhotoFullscreenViewerState();
}

class _PhotoFullscreenViewerState extends State<PhotoFullscreenViewer> {
  late final PageController _pageController;
  late int _currentIndex;

  // Keyed by photo id, populated lazily via putIfAbsent in _fileFutureFor:
  // PageView.builder calls itemBuilder fresh on every rebuild (e.g. every
  // _toggleSelected -> setState/refreshSelection), and building the
  // FutureBuilder's `future:` argument inline there would re-issue a full-
  // resolution file read from disk each time -- this cache makes each
  // page's file only ever get loaded once, no matter how many times the
  // page rebuilds around it.
  final Map<String, Future<File?>> _fileFutures = {};

  // Each page's InteractiveViewer (pinch-to-zoom) and the outer PageView
  // (swipe left/right) both want to claim drag gestures, and PageView
  // tends to win the gesture arena for the first bit of movement -- so
  // starting a 2-finger pinch could get misread as a page-swipe. Tracked
  // via raw pointer count (not GestureDetector's pointer count, which
  // would compete with PageView/InteractiveViewer for the same events) so
  // paging can be fully disabled the instant a second finger touches down,
  // leaving InteractiveViewer's scale gesture uncontested.
  int _activePointerCount = 0;

  void _onPointerDown(PointerDownEvent event) {
    setState(() => _activePointerCount++);
  }

  void _onPointerUp(PointerEvent event) {
    setState(
        () => _activePointerCount = (_activePointerCount - 1).clamp(0, 10));
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  Future<File?> _fileFutureFor(PhotoItem photo) {
    return _fileFutures.putIfAbsent(photo.id, () => _loadFile(photo));
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _toggleSelected() {
    setState(() {
      final photo = widget.photos[_currentIndex];
      photo.isSelected = !photo.isSelected;
    });
    // SummaryBar (a sibling of the review screen's group list, not an
    // ancestor of this viewer) only rebuilds off AppStateProvider, not off
    // direct PhotoItem mutation -- without this it'd show a stale count
    // when returning from a selection made here.
    context.read<AppStateProvider>().refreshSelection();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                // While a 2nd finger is down, disable paging entirely so
                // InteractiveViewer's scale gesture has the arena to itself;
                // otherwise use a higher drag-start threshold than
                // PageScrollPhysics' default so a single-finger swipe needs a
                // more deliberate motion before it's recognized as a page
                // change -- both aimed at the same complaint (pinch-zoom
                // getting misread as swipe-to-next-photo).
                physics: _activePointerCount >= 2
                    ? const NeverScrollableScrollPhysics()
                    : const _LessSensitivePageScrollPhysics(),
                itemCount: widget.photos.length,
                onPageChanged: (index) => setState(() => _currentIndex = index),
                itemBuilder: (context, index) {
                  final p = widget.photos[index];
                  return InteractiveViewer(
                    minScale: 1.0,
                    maxScale: 4.0,
                    child: Center(
                      child: FutureBuilder<File?>(
                        future: _fileFutureFor(p),
                        builder: (context, snapshot) {
                          // These are two different states, not one: "still
                          // waiting" must keep spinning, but "finished with
                          // no file" (deleted/missing asset) previously hit
                          // this same spinner branch and never left it --
                          // the fullscreen view for an already-deleted photo
                          // spun forever instead of showing an error.
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const CircularProgressIndicator(
                              color: Colors.white,
                            );
                          }
                          if (snapshot.data == null) {
                            return const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.broken_image,
                                  color: Colors.white54,
                                  size: 64,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Photo no longer available',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            );
                          }
                          return Image.file(
                            snapshot.data!,
                            fit: BoxFit.contain,
                          );
                        },
                      ),
                    ),
                  );
                },
              ),

              // Top bar: close + position counter.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundIconButton(
                      icon: Icons.close,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        '${_currentIndex + 1}/${widget.photos.length}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    if (photo.isBest)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accentBest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'BEST',
                          style: TextStyle(
                            color: AppColors.bgTop,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 48),
                  ],
                ),
              ),

              // Prev/next navigation arrows.
              if (_currentIndex > 0)
                Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _RoundIconButton(
                      icon: Icons.chevron_left,
                      onPressed: () => _goTo(_currentIndex - 1),
                    ),
                  ),
                ),
              if (_currentIndex < widget.photos.length - 1)
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _RoundIconButton(
                      icon: Icons.chevron_right,
                      onPressed: () => _goTo(_currentIndex + 1),
                    ),
                  ),
                ),

              // Bottom bar: mark-for-deletion checkbox, toggleable from here.
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: Center(
                  child: Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: _toggleSelected,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              photo.isSelected
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Mark for deletion',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<File?> _loadFile(PhotoItem photo) async {
    try {
      final asset = await AssetEntity.fromId(photo.id);
      return await asset?.file;
    } catch (e) {
      debugPrint(
          '[PhotoFullscreenViewer] Error loading file for ${photo.id}: $e');
      return null;
    }
  }
}

/// PageScrollPhysics with a higher drag-start threshold, so a single-finger
/// swipe needs more deliberate initial movement before it's recognized as a
/// page-change gesture -- gives a starting 2-finger pinch (on
/// InteractiveViewer, the page's direct child) less chance of losing the
/// gesture arena to PageView during that first moment of movement.
class _LessSensitivePageScrollPhysics extends PageScrollPhysics {
  const _LessSensitivePageScrollPhysics({super.parent});

  // Flutter's default is kTouchSlop (~18px). Roughly doubled -- enough to
  // meaningfully cut down accidental page-changes without making
  // intentional swipes feel sluggish.
  @override
  double get dragStartDistanceMotionThreshold => 32.0;

  @override
  _LessSensitivePageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _LessSensitivePageScrollPhysics(parent: buildParent(ancestor));
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _RoundIconButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}
