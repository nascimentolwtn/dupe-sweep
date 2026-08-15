import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import 'photo_scanner_service.dart' show ScanCancelledException;
import 'scoring_service.dart';

/// Flags out-of-focus/blurry photos using `ScoringService.computeSharpness`
/// (already correct and unit-tested -- this service just applies it across
/// the whole library and filters).
///
/// Unlike `PhotoScannerService`, this scores EVERY photo, not just
/// time-cluster candidates: blurriness has nothing to do with whether a
/// photo has a duplicate, so every photo needs its own thumbnail fetch and
/// sharpness score -- there's no cheap "skip singletons" shortcut here.
///
/// Deliberately no checkpoint/resume support (unlike
/// `PhotoScannerService`'s `ScanCacheService`-backed Phase 2): a single
/// full pass is simpler, and an interrupted scan just gets redone next
/// time rather than resumed. `isCancelled` still lets a scan in progress
/// be stopped cleanly via the same `ScanCancelledException` signal
/// `PhotoScannerService` uses, so the screen's Cancel button stays
/// responsive even without resumability.
class BlurScanService {
  static const int _kScanConcurrency = 16;

  /// Photos scoring below this on `ScoringService.computeSharpness`'s 0-1
  /// scale (1 = sharpest) are flagged as blurry. Hardcoded for now; wiring
  /// this to the napkin's still-pending Settings screen is a natural
  /// follow-up, not part of this feature.
  static const double kBlurThreshold = 0.15;

  static Future<List<PhotoItem>> scanBlurryPhotos({
    void Function(int current, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    debugPrint('[BlurScan] Starting scan...');

    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(
          ServicesBinding.rootIsolateToken!);
    } catch (e) {
      debugPrint(
          '[BlurScan] BackgroundIsolate already initialized or main thread: $e');
    }

    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (albums.isEmpty) {
      debugPrint('[BlurScan] No albums found!');
      return [];
    }

    final album = albums.first;
    final assetCount = await album.assetCountAsync;
    if (assetCount == 0) return [];

    final allAssets = await album.getAssetListRange(start: 0, end: assetCount);

    final flagged = <PhotoItem>[];
    var completed = 0;

    for (int i = 0; i < allAssets.length; i += _kScanConcurrency) {
      if (isCancelled?.call() == true) {
        throw const ScanCancelledException();
      }

      final chunk = allAssets.skip(i).take(_kScanConcurrency);
      final results = await Future.wait(chunk.map(_scoreSharpness));

      for (final photo in results) {
        if (photo != null && (photo.sharpnessScore ?? 1.0) < kBlurThreshold) {
          flagged.add(photo);
        }
      }

      completed += results.length;
      onProgress?.call(completed, allAssets.length);
    }

    // Blurriest first, so the most obvious candidates for deletion are at
    // the top of the review list.
    flagged.sort(
      (a, b) => (a.sharpnessScore ?? 0).compareTo(b.sharpnessScore ?? 0),
    );

    debugPrint('[BlurScan] Flagged ${flagged.length}/${allAssets.length} '
        'photos below sharpness threshold $kBlurThreshold');

    return flagged;
  }

  static Future<PhotoItem?> _scoreSharpness(AssetEntity asset) async {
    try {
      final thumbData = await asset.thumbnailDataWithSize(
        const ThumbnailSize(200, 200),
      );
      if (thumbData == null) return null;

      final sharpness = ScoringService.computeSharpness(thumbData);

      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: asset.createDateTime,
        fileSize: await asset.fileSize,
        sharpnessScore: sharpness,
      );
    } catch (e) {
      debugPrint('[BlurScan] Error scoring ${asset.id}: $e');
      return null;
    }
  }
}
