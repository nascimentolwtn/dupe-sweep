import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'dart:typed_data';
import '../main.dart';
import '../models/photo_group.dart';
import '../models/photo_item.dart';
import '../screens/photo_fullscreen_viewer.dart';
import '../theme/app_theme.dart';
import '../utils/byte_formatter.dart';

class PhotoGroupCard extends StatefulWidget {
  final PhotoGroup group;

  const PhotoGroupCard({
    Key? key,
    required this.group,
  }) : super(key: key);

  @override
  State<PhotoGroupCard> createState() => _PhotoGroupCardState();
}

class _PhotoGroupCardState extends State<PhotoGroupCard> {
  bool _isExpanded = false;

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
    required this.photo,
    required this.allPhotos,
    required this.index,
  });

  @override
  State<_PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<_PhotoThumbnail> {
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
    // case selection changed while it was open.
    setState(() {});
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
                future: _getThumbnail(photo),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                    );
                  }
                  return Container(
                    color: AppColors.surfaceElevated,
                    child: const Icon(
                      Icons.image_not_supported,
                      color: AppColors.textSecondary,
                    ),
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
      print('Error loading thumbnail: $e');
    }
    return null;
  }
}
