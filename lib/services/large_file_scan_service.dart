import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import 'photo_scanner_service.dart' show ScanCancelledException;

/// Finds the largest photos/videos in the device's media library.
///
/// Deliberately scoped to `photo_manager`'s media library (images + videos
/// via `RequestType.common`), not a general filesystem scan: true "any
/// file" large-file scanning needs `MANAGE_EXTERNAL_STORAGE`, which Google
/// Play restricts to file-manager-role apps -- the same constraint that
/// ruled out a general junk/cache cleaner (napkin backlog #8). This stays
/// within the `READ_MEDIA_IMAGES`/`READ_MEDIA_VIDEO` permissions the app
/// already requests.
///
/// Metadata-only, like `PhotoScannerService`'s Phase 1 -- no thumbnail
/// decode or hashing needed, since size is already available on every
/// asset. That makes this the cheapest of the app's scan modes: no
/// isolate-friendly chunking beyond basic concurrency, no cache/resume
/// support (a full pass is fast enough to just redo if interrupted).
class LargeFileScanService {
  static const int _kScanConcurrency = 16;

  /// Results below this size aren't worth surfacing as "large files".
  static const int kMinFileSizeBytes = 10 * 1024 * 1024; // 10 MB

  /// Caps the result list so the review screen isn't asked to render an
  /// unbounded number of rows on a library with many large videos.
  static const int kMaxResults = 100;

  static Future<List<PhotoItem>> scanLargeFiles({
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    debugPrint('[LargeFileScan] Starting scan...');

    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(
          ServicesBinding.rootIsolateToken!);
    } catch (e) {
      debugPrint(
          '[LargeFileScan] BackgroundIsolate already initialized or main thread: $e');
    }

    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.common,
    );
    if (albums.isEmpty) {
      debugPrint('[LargeFileScan] No albums found!');
      return [];
    }

    final album = albums.first;
    final assetCount = await album.assetCountAsync;
    if (assetCount == 0) return [];

    final allAssets = await album.getAssetListRange(start: 0, end: assetCount);

    final photos = <PhotoItem>[];
    var completed = 0;

    for (int i = 0; i < allAssets.length; i += _kScanConcurrency) {
      if (isCancelled?.call() == true) {
        throw const ScanCancelledException();
      }

      final chunk = allAssets.skip(i).take(_kScanConcurrency);
      final results = await Future.wait(chunk.map(_fetchMetadata));
      photos.addAll(results);
      completed += results.length;
      onProgress?.call(completed, allAssets.length);
    }

    final large = photos.where((p) => p.fileSize >= kMinFileSizeBytes).toList()
      ..sort((a, b) => b.fileSize.compareTo(a.fileSize));

    debugPrint('[LargeFileScan] ${large.length}/${photos.length} assets '
        'at or above ${kMinFileSizeBytes ~/ (1024 * 1024)}MB');

    return large.take(kMaxResults).toList();
  }

  static Future<PhotoItem> _fetchMetadata(AssetEntity asset) async {
    final createDateTime = asset.createDateTime;
    try {
      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: createDateTime,
        fileSize: await asset.fileSize,
      );
    } catch (e) {
      debugPrint('[LargeFileScan] Error fetching metadata for ${asset.id}: $e');
      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: createDateTime,
        fileSize: 0,
      );
    }
  }
}
