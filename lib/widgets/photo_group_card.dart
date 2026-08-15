import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'dart:typed_data';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../screens/photo_fullscreen_viewer.dart';
import '../screens/photo_slider_compare_screen.dart';
import '../theme/app_theme.dart';

class PhotoGroupCard extends StatefulWidget {
  final PhotoGroup group;

  /// One-shot signal from AppStateProvider.pendingExpandGroupId: true when
  /// this card should auto-expand because it's the neighbor of a group
  /// that just vanished from the list (deleted down to nothing left to
  /// compare). Only acted on as a rising edge -- see didUpdateWidget --
  /// so it doesn't fight the user if they manually collapse this card
  /// again afterward.
  final bool forceExpand;

  const PhotoGroupCard({
    super.key,
    required this.group,
    this.forceExpand = false,
  });

  @override
  State<PhotoGroupCard> createState() => _PhotoGroupCardState();
}

class _PhotoGroupCardState extends State<PhotoGroupCard>
    with AutomaticKeepAliveClientMixin<PhotoGroupCard> {
  late bool _isExpanded = widget.forceExpand;

  // Transient "compare" pair-staging: the first photo the user checks the
  // compare-checkbox on in this card, waiting for a second check to open
  // PhotoSliderCompareScreen with both. Scoped to this card's own State
  // (not AppStateProvider) -- it's pure UI staging, not review data, and
  // resets naturally when the card is rebuilt/collapsed.
  PhotoItem? _stagedForCompare;

  // Keeps this card's State (in particular _isExpanded) alive even when
  // ListView.builder's virtualization would otherwise dispose it after
  // scrolling far off-screen -- without this, fast scrolling made expanded
  // groups appear to randomly re-collapse when scrolled back into view,
  // since a freshly-rebuilt State always starts from forceExpand (usually
  // false). Only keeping ALIVE cards expanded (not every card, always)
  // keeps the cost bounded to whatever the user actually has open.
  @override
  bool get wantKeepAlive => _isExpanded;

  @override
  void didUpdateWidget(covariant PhotoGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.forceExpand && !oldWidget.forceExpand) {
      setState(() => _isExpanded = true);
    }
  }

  void _handleCompareCheckboxTap(PhotoItem photo) {
    final staged = _stagedForCompare;
    if (staged == null) {
      setState(() => _stagedForCompare = photo);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select another photo to compare')),
      );
      return;
    }
    if (staged.id == photo.id) {
      // Tapping the already-staged photo's checkbox again clears it.
      setState(() => _stagedForCompare = null);
      return;
    }
    setState(() => _stagedForCompare = null);

    // Left/right is assigned by the photos' order WITHIN THE GROUP, not by
    // which one the user happened to check first -- so the comparison
    // always reads left-to-right the same way the thumbnail row does,
    // regardless of tap order.
    final group = widget.group;
    final stagedIndex = group.photos.indexWhere((p) => p.id == staged.id);
    final photoIndex = group.photos.indexWhere((p) => p.id == photo.id);
    final PhotoItem left;
    final PhotoItem right;
    if (stagedIndex <= photoIndex) {
      left = staged;
      right = photo;
    } else {
      left = photo;
      right = staged;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoSliderCompareScreen(left: left, right: right),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final group = widget.group;
    final dateStr =
        '${group.timestamp.year}-${group.timestamp.month.toString().padLeft(2, '0')}-${group.timestamp.day.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateStr,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        '${group.photos.length} photos',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      if (group.selectedCount > 0)
                        Chip(
                          label: Text('${group.selectedCount} selected'),
                          backgroundColor: AppColors.accentViolet.withAlpha(90),
                        ),
                      const SizedBox(width: 8),
                      // Decorative only -- the whole header row above
                      // handles the tap via the InkWell it's wrapped in,
                      // so this doesn't need its own onPressed.
                      Icon(
                        _isExpanded ? Icons.expand_less : Icons.expand_more,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded) ...[
            const Divider(height: 0),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: group.photos.asMap().entries.map((entry) {
                  return _PhotoThumbnail(
                    // Ties this widget's State to the photo's identity, not
                    // its position in the list -- without this, deleting a
                    // photo can make Flutter reuse another thumbnail's
                    // State (and its already-fetched image future) for a
                    // different photo that shifted into its old index.
                    key: ValueKey(entry.value.id),
                    photo: entry.value,
                    allPhotos: group.photos,
                    index: entry.key,
                    isStagedForCompare: _stagedForCompare?.id == entry.value.id,
                    onCompareTap: () => _handleCompareCheckboxTap(entry.value),
                  );
                }).toList(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      group.selectAllNonBest();
                      setState(() {});
                      context.read<AppStateProvider>().refreshSelection();
                    },
                    icon: const Icon(Icons.check_box),
                    label: const Text('Select All Non-Best'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      group.deselectAll();
                      setState(() {});
                      context.read<AppStateProvider>().refreshSelection();
                    },
                    icon: const Icon(Icons.close),
                    label: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PhotoThumbnail extends StatefulWidget {
  final PhotoItem photo;
  final List<PhotoItem> allPhotos;
  final int index;
  final bool isStagedForCompare;
  final VoidCallback onCompareTap;

  const _PhotoThumbnail({
    super.key,
    required this.photo,
    required this.allPhotos,
    required this.index,
    required this.isStagedForCompare,
    required this.onCompareTap,
  });

  @override
  State<_PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<_PhotoThumbnail> {
  // Fetched once in initState, not on every build(): building this future
  // inline inside FutureBuilder's `future:` argument re-issues a fresh
  // platform-channel thumbnail request every time this widget rebuilds --
  // which now happens on every selection tap anywhere in the group, since
  // that calls AppStateProvider.refreshSelection() and rebuilds the whole
  // Consumer subtree. Memoizing here means a rebuild just re-renders with
  // the already-fetched image instead of flashing back to a placeholder
  // and re-fetching.
  late Future<Uint8List?> _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = _getThumbnail(widget.photo);
  }

  Future<void> _openFullscreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoFullscreenViewer(
          photos: widget.allPhotos,
          initialIndex: widget.index,
        ),
      ),
    );
    // The viewer mutates the same PhotoItem instances directly; refresh in
    // case selection changed while it was open. Guarded: the group could
    // have been removed from the review list (e.g. deleted down to a
    // singleton) while the fullscreen viewer was on top, unmounting this
    // widget before the pushed route returns.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: GestureDetector(
        onTap: _openFullscreen,
        child: Stack(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(
                  color: widget.isStagedForCompare
                      ? AppColors.accentViolet
                      : photo.isSelected
                          ? AppColors.accentCyan
                          : Colors.white24,
                  width: widget.isStagedForCompare || photo.isSelected ? 3 : 1,
                ),
              ),
              child: FutureBuilder<Uint8List?>(
                future: _thumbnailFuture,
                builder: (context, snapshot) {
                  // "Still loading" and "finished but failed/missing" are
                  // different states -- the fullscreen viewer used to
                  // conflate an equivalent pair of states into a spinner
                  // that never left; this widget had the opposite bug,
                  // showing "not supported" for a thumbnail that just
                  // hasn't finished loading yet.
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (snapshot.data == null) {
                    return Container(
                      color: AppColors.surfaceElevated,
                      child: const Icon(
                        Icons.image_not_supported,
                        color: AppColors.textSecondary,
                      ),
                    );
                  }
                  return Image.memory(
                    snapshot.data!,
                    fit: BoxFit.cover,
                  );
                },
              ),
            ),
            // Checkbox: its own tap target, on top of (and independent
            // from) the thumbnail's tap-to-open-fullscreen behavior below.
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    photo.isSelected = !photo.isSelected;
                  });
                  context.read<AppStateProvider>().refreshSelection();
                },
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    photo.isSelected
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    color:
                        photo.isSelected ? AppColors.accentCyan : Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
            // Compare-checkbox: bottom-right, its own tap target (mirrors
            // the delete-checkbox's top-right pattern). Checking a 2nd
            // photo's box in the same group immediately opens the slider
            // compare screen for the two -- see
            // _PhotoGroupCardState._handleCompareCheckboxTap.
            Positioned(
              bottom: 4,
              right: 4,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onCompareTap,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    widget.isStagedForCompare
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    color: widget.isStagedForCompare
                        ? AppColors.accentViolet
                        : Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
            if (photo.isBest)
              Positioned(
                bottom: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accentBest,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text(
                    'BEST',
                    style: TextStyle(
                      color: AppColors.bgTop,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List?> _getThumbnail(PhotoItem photo) async {
    try {
      final asset = await AssetEntity.fromId(photo.id);
      if (asset != null) {
        return await asset.thumbnailDataWithSize(
          const ThumbnailSize(200, 200),
        );
      }
    } catch (e) {
      debugPrint('Error loading thumbnail: $e');
    }
    return null;
  }
}
