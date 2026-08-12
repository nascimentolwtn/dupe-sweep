import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../main.dart';
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
    final dateStr = '${group.timestamp.year}-${group.timestamp.month.toString().padLeft(2, '0')}-${group.timestamp.day.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.all(8),
      child: Column(
        children: [
          Padding(
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
                      ),
                    ),
                    Text(
                      '${group.photos.length} photos',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
                Row(
                  children: [
                    if (group.selectedCount > 0)
                      Chip(
                        label: Text('${group.selectedCount} selected'),
                        backgroundColor: Colors.blue.withAlpha(100),
                      ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        _isExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                      ),
                      onPressed: () {
                        setState(() {
                          _isExpanded = !_isExpanded;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_isExpanded) ...[
            const Divider(height: 0),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: group.photos.map((photo) {
                  return _PhotoThumbnail(photo: photo);
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
                    },
                    icon: const Icon(Icons.check_box),
                    label: const Text('Select All Non-Best'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      group.deselectAll();
                      setState(() {});
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

  const _PhotoThumbnail({required this.photo});

  @override
  State<_PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<_PhotoThumbnail> {
  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: GestureDetector(
        onTap: () {
          setState(() {
            photo.isSelected = !photo.isSelected;
          });
        },
        child: Stack(
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(
                  color: photo.isSelected ? Colors.blue : Colors.grey,
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
                    color: Colors.grey[300],
                    child: const Icon(Icons.image_not_supported),
                  );
                },
              ),
            ),
            if (photo.isSelected)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Colors.white,
                    size: 20,
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
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Text(
                    'BEST',
                    style: TextStyle(
                      color: Colors.white,
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
