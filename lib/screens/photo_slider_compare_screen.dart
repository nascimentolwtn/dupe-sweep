import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import '../main.dart';
import '../models/photo_item.dart';
import '../theme/app_theme.dart';

/// Clamps a raw drag-derived slider position into the valid 0.0-1.0 range.
/// Factored out as a pure function (rather than inlined in a drag handler)
/// so the divider math is unit-testable without a widget test.
double clampSliderPosition(double value) => value.clamp(0.0, 1.0);

/// Overlapping 2-photo comparison: [right] renders full-bleed as the base
/// layer, [left] is clipped to a width (growing from the screen's left edge
/// as the divider moves right) driven by a drag handle -- so dragging the
/// divider right reveals more of [left] (matching a reader's mental model:
/// "the region left of the divider is the left photo"), and dragging left
/// reveals more of [right]. Easier to spot subtle framing/sharpness
/// differences than switching between two separate fullscreen pages.
///
/// Mirrors `PhotoFullscreenViewer`'s full-resolution file loading
/// (`_fileFutureFor`/`_loadFile`) and mark-for-deletion toggle
/// (`_toggleSelected`) since [left]/[right] are the SAME [PhotoItem]
/// instances the calling `PhotoGroupCard` holds -- toggling selection here
/// mutates them directly, and the card picks up the change via its own
/// `setState` after this screen is popped.
class PhotoSliderCompareScreen extends StatefulWidget {
  final PhotoItem left;
  final PhotoItem right;

  const PhotoSliderCompareScreen({
    super.key,
    required this.left,
    required this.right,
  });

  @override
  State<PhotoSliderCompareScreen> createState() =>
      _PhotoSliderCompareScreenState();
}

class _PhotoSliderCompareScreenState extends State<PhotoSliderCompareScreen> {
  static const double _kMinZoom = 1.0;
  static const double _kMaxZoom = 4.0;
  static const double _kZoomStep = 0.5;
  static const double _kPanStep = 40.0;

  double _sliderPosition = 0.5;
  // Applied identically to both photo layers (see _PhotoLayer's `scale`)
  // rather than an independent pinch-to-zoom per photo -- the two photos
  // need to zoom in lockstep, anchored to the same center point, or the
  // comparison stops lining up. +/- buttons sidestep the gesture conflict
  // pinch-to-zoom would have had with the divider's own drag gesture.
  double _zoomLevel = _kMinZoom;
  // Also applied identically to both layers, same reasoning as zoom --
  // panning one photo without the other would misalign the comparison.
  // Arrow buttons (not drag) for the same reason zoom uses buttons: a pan
  // gesture on the image area would fight the divider's own drag gesture.
  Offset _panOffset = Offset.zero;
  late final Future<File?> _leftFileFuture;
  late final Future<File?> _rightFileFuture;

  // Captured each build from the LayoutBuilder inside the image area (see
  // build()) so the AppBar's zoom buttons -- built outside that
  // LayoutBuilder -- can still clamp pan against the real viewport size.
  Size _viewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _leftFileFuture = _loadFile(widget.left);
    _rightFileFuture = _loadFile(widget.right);
  }

  void _zoomIn(Size viewportSize) {
    setState(() {
      _zoomLevel = (_zoomLevel + _kZoomStep).clamp(_kMinZoom, _kMaxZoom);
      _panOffset = _clampPan(_panOffset, viewportSize);
    });
  }

  void _zoomOut(Size viewportSize) {
    setState(() {
      _zoomLevel = (_zoomLevel - _kZoomStep).clamp(_kMinZoom, _kMaxZoom);
      _panOffset = _clampPan(_panOffset, viewportSize);
    });
  }

  void _pan(Offset delta, Size viewportSize) {
    setState(() {
      _panOffset = _clampPan(_panOffset + delta, viewportSize);
    });
  }

  /// Keeps the pan offset within roughly how far the zoomed content
  /// actually extends past the viewport on each side -- at `_kMinZoom`
  /// (nothing to pan into) this clamps to zero; the allowed range grows
  /// with zoom level. Approximate (BoxFit.contain's letterboxing means the
  /// true edge depends on each photo's aspect ratio, which isn't known
  /// here), but close enough to stop panning off into empty space.
  Offset _clampPan(Offset offset, Size viewportSize) {
    final maxX = (_zoomLevel - 1) * viewportSize.width / 2;
    final maxY = (_zoomLevel - 1) * viewportSize.height / 2;
    return Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
  }

  Future<File?> _loadFile(PhotoItem photo) async {
    try {
      final asset = await AssetEntity.fromId(photo.id);
      return await asset?.file;
    } catch (e) {
      debugPrint('[PhotoSliderCompare] Error loading file for ${photo.id}: $e');
      return null;
    }
  }

  void _toggleSelected(PhotoItem photo) {
    setState(() {
      photo.isSelected = !photo.isSelected;
    });
    context.read<AppStateProvider>().refreshSelection();
  }

  void _updateSliderFromLocalX(double localX, double width) {
    if (width <= 0) return;
    setState(() {
      _sliderPosition = clampSliderPosition(localX / width);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Compare Photos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed:
                _zoomLevel > _kMinZoom ? () => _zoomOut(_viewportSize) : null,
            tooltip: 'Zoom out',
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            onPressed:
                _zoomLevel < _kMaxZoom ? () => _zoomIn(_viewportSize) : null,
            tooltip: 'Zoom in',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final viewportSize =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  _viewportSize = viewportSize;
                  return GestureDetector(
                    onHorizontalDragUpdate: (details) =>
                        _updateSliderFromLocalX(
                            details.localPosition.dx, width),
                    onTapDown: (details) => _updateSliderFromLocalX(
                        details.localPosition.dx, width),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Base layer: shows through in the region right of
                        // the divider (not covered by the clipped layer
                        // below).
                        _PhotoLayer(
                          fileFuture: _rightFileFuture,
                          scale: _zoomLevel,
                          pan: _panOffset,
                        ),
                        // Right's BEST badge shares the base layer's
                        // territory, so it's clipped to the inverse of the
                        // left clip -- the region NOT covered by the left
                        // layer -- rather than pinned to a fixed corner. As
                        // the divider drags right and the left layer grows
                        // over the top-right corner, this badge is clipped
                        // away along with the right photo underneath it, so
                        // it never claims "best" over what's now visibly
                        // the left photo.
                        if (widget.right.isBest)
                          ClipRect(
                            clipper: _InverseSliderClipper(_sliderPosition),
                            child: const Align(
                              alignment: Alignment.topRight,
                              child: Padding(
                                padding: EdgeInsets.only(top: 8, right: 8),
                                child: _BestBadge(),
                              ),
                            ),
                          ),
                        // Clipped layer: visible region grows from the
                        // screen's left edge as _sliderPosition increases,
                        // so dragging the divider right reveals more of
                        // `left` -- see class doc comment. Clip is applied
                        // OUTSIDE the zoomed content, so the divider
                        // boundary stays put on screen as you zoom -- only
                        // the photo pixels within each side get bigger.
                        // Left's BEST badge lives inside this same clip
                        // (mirroring right's badge above) so it disappears
                        // together with the left photo once the divider
                        // moves back past it.
                        ClipRect(
                          clipper: _SliderClipper(_sliderPosition),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _PhotoLayer(
                                fileFuture: _leftFileFuture,
                                scale: _zoomLevel,
                                pan: _panOffset,
                              ),
                              if (widget.left.isBest)
                                const Positioned(
                                  left: 8,
                                  top: 8,
                                  child: _BestBadge(),
                                ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: width * _sliderPosition - 1,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: Colors.white70),
                        ),
                        Positioned(
                          left: (width * _sliderPosition - 18).clamp(
                            0,
                            width - 36,
                          ),
                          top: 0,
                          bottom: 0,
                          child: const Center(
                            child: _DragHandle(),
                          ),
                        ),
                        // Pan arrows on the 4 screen edges (not a corner
                        // D-pad) -- only shown while zoomed, since at
                        // _kMinZoom there's nowhere to pan to (_clampPan
                        // forces the offset to zero either way).
                        if (_zoomLevel > _kMinZoom) ...[
                          Positioned(
                            top: 8,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: _PanButton(
                                icon: Icons.keyboard_arrow_up,
                                onPressed: () => _pan(
                                  const Offset(0, _kPanStep),
                                  viewportSize,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 8,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: _PanButton(
                                icon: Icons.keyboard_arrow_down,
                                onPressed: () => _pan(
                                  const Offset(0, -_kPanStep),
                                  viewportSize,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 8,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: _PanButton(
                                icon: Icons.keyboard_arrow_left,
                                onPressed: () => _pan(
                                  const Offset(_kPanStep, 0),
                                  viewportSize,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 8,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: _PanButton(
                                icon: Icons.keyboard_arrow_right,
                                onPressed: () => _pan(
                                  const Offset(-_kPanStep, 0),
                                  viewportSize,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            _CompareControlsBar(
              left: widget.left,
              right: widget.right,
              onToggleLeft: () => _toggleSelected(widget.left),
              onToggleRight: () => _toggleSelected(widget.right),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderClipper extends CustomClipper<Rect> {
  final double position;

  _SliderClipper(this.position);

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * position, size.height);

  @override
  bool shouldReclip(covariant _SliderClipper oldClipper) =>
      oldClipper.position != position;
}

/// Complement of [_SliderClipper]: clips to the region right of the
/// divider instead of left of it, so a widget using this clipper is
/// visible exactly where [_SliderClipper] is NOT -- used to hide the
/// right photo's BEST badge once the left layer grows over it.
class _InverseSliderClipper extends CustomClipper<Rect> {
  final double position;

  _InverseSliderClipper(this.position);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
        size.width * position,
        0,
        size.width * (1 - position),
        size.height,
      );

  @override
  bool shouldReclip(covariant _InverseSliderClipper oldClipper) =>
      oldClipper.position != position;
}

class _PhotoLayer extends StatelessWidget {
  final Future<File?> fileFuture;
  final double scale;
  final Offset pan;

  const _PhotoLayer({
    required this.fileFuture,
    required this.scale,
    required this.pan,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        if (snapshot.data == null) {
          return const Center(
            child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
          );
        }
        // Transform.scale/translate (not baked into the clip/layout) so
        // this layer's own bounds stay unchanged -- the surrounding
        // Stack/ClipRect still clips any zoomed-in overflow at the same
        // screen position as before, it just now contains more zoomed-in,
        // panned photo detail. Default `Alignment.center` scaling plus the
        // SAME `pan` offset on both layers keeps them moving in lockstep,
        // so they stay aligned with each other as zoom/pan change.
        // `translate` wraps `scale` (applied in outer, unscaled space) so
        // each pan-button tap moves the image by the same screen distance
        // regardless of zoom level.
        return Transform.translate(
          offset: pan,
          child: Transform.scale(
            scale: scale,
            child: Image.file(
              snapshot.data!,
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }
}

/// Round icon button for the pan arrows (see build()'s "Pan arrows on the
/// 4 screen edges" block) -- buttons rather than a drag gesture on the
/// image area, which would otherwise fight the divider's own drag-to-move
/// gesture in the same region. Also doubles as the visual style for the
/// prev/next-style edge controls, matching PhotoFullscreenViewer's
/// _RoundIconButton.
class _PanButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _PanButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 20),
        onPressed: onPressed,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Same styling as `PhotoFullscreenViewer`'s inline "BEST" badge.
class _BestBadge extends StatelessWidget {
  const _BestBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(
        color: Colors.white70,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.drag_indicator, color: Colors.black, size: 20),
    );
  }
}

class _CompareControlsBar extends StatelessWidget {
  final PhotoItem left;
  final PhotoItem right;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;

  const _CompareControlsBar({
    required this.left,
    required this.right,
    required this.onToggleLeft,
    required this.onToggleRight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: _MarkForDeleteButton(
              label: 'Mark left',
              isSelected: left.isSelected,
              onPressed: onToggleLeft,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MarkForDeleteButton(
              label: 'Mark right',
              isSelected: right.isSelected,
              onPressed: onToggleRight,
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkForDeleteButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onPressed;

  const _MarkForDeleteButton({
    required this.label,
    required this.isSelected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: isSelected ? AppColors.danger : AppColors.textPrimary,
        side: BorderSide(
          color: isSelected ? AppColors.danger : AppColors.border,
        ),
      ),
      icon: Icon(
        isSelected ? Icons.check_box : Icons.check_box_outline_blank,
      ),
      label: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}
