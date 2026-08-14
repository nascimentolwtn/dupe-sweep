import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

class DeletionService {
  /// Delete a list of photos by their IDs in a single batched call.
  ///
  /// Returns the IDs actually deleted -- on Android this is one system
  /// confirmation dialog for the whole batch, not one per photo (the
  /// previous version called `deleteWithIds` once per ID in a loop, which
  /// meant one OS prompt per photo). Callers need the actual deleted-ID
  /// list, not just a count, since the user can decline the OS prompt and
  /// the app must only remove genuinely-deleted photos from its own state.
  static Future<List<String>> deletePhotos(List<String> photoIds) async {
    if (photoIds.isEmpty) return [];

    debugPrint('[DeletionService] Requesting delete of ${photoIds.length} '
        'photos: $photoIds');
    try {
      final result = await PhotoManager.editor.deleteWithIds(photoIds);
      debugPrint('[DeletionService] OS confirmed deletion of ${result.length}/'
          '${photoIds.length} photos: $result');
      return result;
    } catch (e) {
      debugPrint('[DeletionService] Error deleting photos: $e');
      return [];
    }
  }

  /// Permanently delete a single photo.
  static Future<bool> deletePhoto(String photoId) async {
    try {
      final result = await PhotoManager.editor.deleteWithIds([photoId]);
      return result.isNotEmpty;
    } catch (e) {
      debugPrint('Error deleting photo $photoId: $e');
      return false;
    }
  }
}
