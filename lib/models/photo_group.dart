import 'photo_item.dart';

class PhotoGroup {
  final String id;
  final List<PhotoItem> photos;
  final DateTime timestamp;
  final String groupType; // 'time', 'hash', 'combined'

  PhotoGroup({
    required this.id,
    required this.photos,
    required this.timestamp,
    this.groupType = 'time',
  });

  int get totalSize => photos.fold(0, (sum, photo) => sum + photo.fileSize);

  int get selectedCount => photos.where((p) => p.isSelected).length;

  // No `!isBest` filter: isBest is only a heuristic guess the user can
  // override, including deleting every photo in a group.
  int get deleteCount => photos.where((p) => p.isSelected).length;

  int get reclaimableBytes {
    int total = 0;
    for (var photo in photos) {
      if (photo.isSelected) {
        total += photo.fileSize;
      }
    }
    return total;
  }

  void selectAllNonBest() {
    for (var photo in photos) {
      if (!photo.isBest) {
        photo.isSelected = true;
      }
    }
  }

  void deselectAll() {
    for (var photo in photos) {
      photo.isSelected = false;
    }
  }

  /// Marks the largest-file-size photo as [PhotoItem.isBest] if the group
  /// doesn't already have one -- a no-op otherwise. This is the same
  /// stopgap heuristic used when a group is first built (see
  /// `buildPhotoGroups` in scan_progress_screen.dart), factored out here
  /// so it can also run after a group loses photos to deletion: without
  /// re-electing, a group whose isBest photo got deleted would have NO
  /// best photo left, and "Select All Non-Best" would select every
  /// remaining photo with no warning.
  void ensureBestElected() {
    if (photos.isEmpty || photos.any((p) => p.isBest)) return;
    photos.reduce((a, b) => b.fileSize > a.fileSize ? b : a).isBest = true;
  }
}
