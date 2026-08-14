import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import 'scan_cache_service.dart';
import 'similarity_service.dart';

class PhotoScannerService {
  /// Number of photos processed concurrently per chunk. Matches the
  /// Python reference implementation's `ThreadPoolExecutor(max_workers=16)`,
  /// which is already empirically validated against real device I/O
  /// characteristics for this use case.
  static const int _kScanConcurrency = 16;

  /// [cache] is an optional save-point service. When provided:
  ///  - already-processed assets (per `cache.cachedEntries`) are
  ///    reconstructed from cached data instead of being re-hashed.
  ///  - newly-processed assets are recorded into the cache and periodically
  ///    checkpointed to disk, so an interrupted scan can resume later.
  /// Passing `null` (the default) preserves today's behavior exactly --
  /// no caching, useful for existing tests / simple callers.
  static Future<List<PhotoItem>> scanAllPhotos({
    Function(int, int)? onProgress,
    ScanCacheService? cache,
  }) async {
    try {
      print('[PhotoScanner] Starting scan...');

      // Initialize background isolate for platform channels
      try {
        BackgroundIsolateBinaryMessenger.ensureInitialized(
            ServicesBinding.rootIsolateToken!);
        print('[PhotoScanner] BackgroundIsolate initialized');
      } catch (e) {
        print(
            '[PhotoScanner] BackgroundIsolate already initialized or main thread: $e');
      }

      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );

      print('[PhotoScanner] Found ${albums.length} albums');
      if (albums.isEmpty) {
        print('[PhotoScanner] No albums found!');
        return [];
      }

      final album = albums.first;
      final assetCount = await album.assetCountAsync;
      print('[PhotoScanner] Album has $assetCount assets');

      if (assetCount == 0) {
        print('[PhotoScanner] Album is empty!');
        return [];
      }

      final allAssets = await album.getAssetListRange(
        start: 0,
        end: assetCount,
      );

      print('[PhotoScanner] Retrieved ${allAssets.length} assets');

      if (cache != null) {
        if (!cache.isLoaded) {
          await cache.load();
        }
        cache.setTotalKnownAssets(allAssets.length);
      }

      final photos = <PhotoItem>[];
      var completed = 0;

      for (int i = 0; i < allAssets.length; i += _kScanConcurrency) {
        final chunk = allAssets.skip(i).take(_kScanConcurrency);

        final chunkFutures = chunk.map((asset) {
          final cached = cache?.cachedEntries[asset.id];
          if (cached != null) {
            // Already processed in a prior (interrupted) scan -- reconstruct
            // without re-hashing.
            final photo = PhotoItem(
              id: asset.id,
              path: asset.relativePath ?? 'Unknown',
              createDateTime: DateTime.fromMillisecondsSinceEpoch(
                  cached.createDateTimeMillis),
              fileSize: cached.fileSize,
              dhash: cached.dhash,
            );
            photos.add(photo);
            completed++;
            onProgress?.call(completed, allAssets.length);
            return Future.value(photo);
          }

          return _processAsset(asset).then((photo) async {
            photos.add(photo);
            completed++;
            onProgress?.call(completed, allAssets.length);

            cache?.recordProcessed(
              asset.id,
              CachedPhotoData(
                dhash: photo.dhash,
                createDateTimeMillis:
                    photo.createDateTime.millisecondsSinceEpoch,
                fileSize: photo.fileSize,
              ),
            );
            await cache?.maybeCheckpoint();

            return photo;
          });
        });

        await Future.wait(chunkFutures);
      }

      // Sort by create date
      photos.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));

      return photos;
    } catch (e) {
      print('[PhotoScanner] ERROR: $e');
      print('[PhotoScanner] StackTrace: $e');
      return [];
    }
  }

  /// Processes a single asset: fetches its thumbnail, computes a dHash,
  /// fetches its file size, and returns the resulting [PhotoItem]. Mirrors
  /// what one iteration of the old sequential loop did, but does not report
  /// progress itself — callers drive progress reporting per-completed-item.
  ///
  /// Defensively wrapped so a single asset's platform-call failure can't
  /// crash the `Future.wait` for its chunk; on unexpected failure this
  /// returns a best-effort [PhotoItem] with fallback fields rather than
  /// dropping the asset from the scan.
  static Future<PhotoItem> _processAsset(AssetEntity asset) async {
    final createDateTime = asset.createDateTime ?? DateTime.now();

    try {
      // Compute dHash from thumbnail
      String? dhash;
      try {
        final thumbData = await asset.thumbnailDataWithSize(
          const ThumbnailSize(200, 200),
        );
        if (thumbData != null) {
          dhash = SimilarityService.computeDHash(thumbData);
        }
      } catch (e) {
        print('Error computing hash for ${asset.id}: $e');
      }

      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: createDateTime,
        fileSize: await asset.fileSize,
        dhash: dhash,
      );
    } catch (e) {
      print('[PhotoScanner] Error processing asset ${asset.id}: $e');
      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: createDateTime,
        fileSize: 0,
        dhash: null,
      );
    }
  }
}
