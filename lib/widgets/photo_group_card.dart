import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'dart:typed_data';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../screens/photo_fullscreen_viewer.dart';
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

class _PhotoGroupCardState extends State<PhotoGroupCard> {
  late bool _isExpanded = widget.forceExpand;

  @override
  void didUpdateWidget(covariant PhotoGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.forceExpand && !oldWidget.forceExpand) {
      setState(() => _isExpanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
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

  const _PhotoThumbnail({
    super.key,
    required this.photo,
    required this.allPhotos,
    required this.index,
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
                  color:
                      photo.isSelected ? AppColors.accentCyan : Colors.white24,
                  width: photo.isSelected ? 3 : 1,
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
