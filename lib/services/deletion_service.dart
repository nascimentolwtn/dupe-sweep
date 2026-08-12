import 'package:photo_manager/photo_manager.dart';

class DeletionService {
  /// Delete a list of photos by their IDs.
  /// Returns the number of photos successfully deleted.
  static Future<int> deletePhotos(List<String> photoIds) async {
    int deletedCount = 0;

    try {
      for (final id in photoIds) {
        final asset = await AssetEntity.fromId(id);
        if (asset != null) {
          final result = await PhotoManager.editor.deleteWithIds([id]);
          if (result.isNotEmpty) {
            deletedCount++;
          }
        }
      }
    } catch (e) {
      print('Error deleting photos: $e');
    }

    return deletedCount;
  }

  /// Permanently delete a single photo.
  static Future<bool> deletePhoto(String photoId) async {
    try {
      final result = await PhotoManager.editor.deleteWithIds([photoId]);
      return result.isNotEmpty;
    } catch (e) {
      print('Error deleting photo $photoId: $e');
      return false;
    }
  }
}
