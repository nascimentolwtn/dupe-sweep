import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import 'scan_cache_service.dart';
import 'similarity_service.dart';

/// Thrown by [PhotoScannerService.scanAllPhotos] when `isCancelled` reports
/// true partway through a scan. Callers should catch this specifically --
/// unlike other scan errors, a cancellation isn't a failure to report, it's
/// an expected user action, and any progress already made was flushed to
/// [ScanCacheService] before this was thrown, so a later "Resume scan" is
/// available.
class ScanCancelledException implements Exception {
  const ScanCancelledException();

  @override
  String toString() => 'Scan cancelled by user';
}

class PhotoScannerService {
  /// Number of photos processed concurrently per chunk. Matches the
  /// Python reference implementation's `ThreadPoolExecutor(max_workers=16)`,
  /// which is already empirically validated against real device I/O
  /// characteristics for this use case.
  static const int _kScanConcurrency = 16;

  /// Scans the library in two phases instead of hashing every photo
  /// up front:
  ///
  ///  - **Phase 1 (metadata)**: fetches `createDateTime`/`fileSize` for
  ///    every photo. Cheap enough (no thumbnail decode) to always run in
  ///    full, so it is NOT cache-backed -- an interrupted/resumed scan
  ///    simply redoes it.
  ///  - **Phase 2 (hashing)**: `SimilarityService.clusterByTime` is run on
  ///    the Phase 1 results to find which photos share a rolling
  ///    time-window cluster with at least one other photo. Only those
  ///    photos ever get sub-grouped by hash in `buildPhotoGroups`
  ///    (`scan_progress_screen.dart`) -- a lone photo in its own cluster is
  ///    always its own review group regardless of its hash -- so only
  ///    those "candidate" photos get a thumbnail fetched and a dHash
  ///    computed. This is the expensive step, so it IS cache-backed via
  ///    [cache]: already-hashed candidates from an interrupted prior run
  ///    are reused instead of re-hashed.
  ///
  /// [cache], when provided: loads existing progress (if not already
  /// loaded by the caller), skips re-hashing candidates already recorded,
  /// and periodically checkpoints newly-hashed candidates to disk so an
  /// interrupted scan can resume later. Passing `null` (the default)
  /// disables caching entirely -- useful for existing tests/simple callers.
  ///
  /// [isCancelled], when provided, is polled between chunks (roughly every
  /// [_kScanConcurrency] photos). If it ever returns true, the scan flushes
  /// [cache] (so progress isn't lost) and throws [ScanCancelledException]
  /// instead of returning -- this is a deliberate user action, not an
  /// error, so callers should catch it separately from other failures.
  static Future<List<PhotoItem>> scanAllPhotos({
    void Function(int current, int total, String phase)? onProgress,
    ScanCacheService? cache,
    bool Function()? isCancelled,
  }) async {
    try {
      debugPrint('[PhotoScanner] Starting scan...');

      // Initialize background isolate for platform channels
      try {
        BackgroundIsolateBinaryMessenger.ensureInitialized(
            ServicesBinding.rootIsolateToken!);
        debugPrint('[PhotoScanner] BackgroundIsolate initialized');
      } catch (e) {
        debugPrint(
            '[PhotoScanner] BackgroundIsolate already initialized or main thread: $e');
      }

      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );

      debugPrint('[PhotoScanner] Found ${albums.length} albums');
      if (albums.isEmpty) {
        debugPrint('[PhotoScanner] No albums found!');
        return [];
      }

      final album = albums.first;
      final assetCount = await album.assetCountAsync;
      debugPrint('[PhotoScanner] Album has $assetCount assets');

      if (assetCount == 0) {
        debugPrint('[PhotoScanner] Album is empty!');
        return [];
      }

      final allAssets = await album.getAssetListRange(
        start: 0,
        end: assetCount,
      );

      debugPrint('[PhotoScanner] Retrieved ${allAssets.length} assets');

      if (cache != null && !cache.isLoaded) {
        await cache.load();
      }

      // ---- Phase 1: metadata only (no thumbnail/hash work). ----
      const phase1Label = 'Reading photo library';
      const phase2Label = 'Checking for duplicates';

      final photosById = <String, PhotoItem>{};
      var metadataCompleted = 0;
      final metadataTotal = allAssets.length;

      for (int i = 0; i < allAssets.length; i += _kScanConcurrency) {
        if (isCancelled?.call() == true) {
          await cache?.flush();
          throw const ScanCancelledException();
        }

        final chunk = allAssets.skip(i).take(_kScanConcurrency);

        await Future.wait(chunk.map((asset) async {
          final photo = await _fetchMetadata(asset);
          photosById[photo.id] = photo;
          metadataCompleted++;
          onProgress?.call(metadataCompleted, metadataTotal, phase1Label);
        }));
      }

      final metadataPhotos = photosById.values.toList()
        ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));

      // ---- Determine which photos actually need a perceptual hash. ----
      final clusters = SimilarityService.clusterByTime(metadataPhotos);
      final candidateIds = <String>{
        for (final cluster in clusters)
          if (cluster.length > 1) ...cluster.map((p) => p.id),
      };

      final candidateAssets =
          allAssets.where((a) => candidateIds.contains(a.id)).toList();

      debugPrint('[PhotoScanner] ${candidateAssets.length}/${allAssets.length} '
          'photos share a time cluster and need hashing '
          '(${allAssets.length - candidateAssets.length} skipped as singletons)');

      // Now that we know how much hashing work actually remains, this is
      // the meaningful "total" for a resume prompt -- not the whole
      // library size, which Phase 1 (uncached) always redoes anyway.
      cache?.setTotalKnownAssets(candidateAssets.length);

      // ---- Phase 2: hash only the candidates, cache-backed. A distinct
      // phase, so progress restarts at 0 against its own (smaller) total
      // rather than continuing against Phase 1's total -- the two phases
      // do very different work at very different speeds, and silently
      // reusing one running total made the bar look like it jumped
      // backwards when Phase 2 began.
      final hashTotal = candidateAssets.length;
      var hashCompleted = 0;
      if (hashTotal > 0) {
        onProgress?.call(hashCompleted, hashTotal, phase2Label);
      }

      for (int i = 0; i < candidateAssets.length; i += _kScanConcurrency) {
        if (isCancelled?.call() == true) {
          await cache?.flush();
          throw const ScanCancelledException();
        }

        final chunk = candidateAssets.skip(i).take(_kScanConcurrency);

        await Future.wait(chunk.map((asset) async {
          final existing = photosById[asset.id]!;
          final cached = cache?.cachedEntries[asset.id];

          if (cached != null) {
            // Already hashed (or already attempted) in a prior interrupted
            // run -- reuse it rather than re-hashing.
            photosById[asset.id] = existing.copyWith(dhash: cached.dhash);
          } else {
            final dhash = await _computeHash(asset);
            photosById[asset.id] = existing.copyWith(dhash: dhash);

            cache?.recordProcessed(
              asset.id,
              CachedPhotoData(
                dhash: dhash,
                createDateTimeMillis:
                    existing.createDateTime.millisecondsSinceEpoch,
                fileSize: existing.fileSize,
              ),
            );
            await cache?.maybeCheckpoint();
          }

          hashCompleted++;
          onProgress?.call(hashCompleted, hashTotal, phase2Label);
        }));
      }

      final photos = photosById.values.toList()
        ..sort((a, b) => a.createDateTime.compareTo(b.createDateTime));

      return photos;
    } on ScanCancelledException {
      // Must not be swallowed by the catch-all below: this is a deliberate
      // user action, not a scan failure, and callers need to handle it
      // distinctly (see `ScanCancelledException`'s doc comment).
      rethrow;
    } catch (e, stackTrace) {
      // Rethrow rather than returning [] -- a real failure here (e.g.
      // permission revoked mid-scan, PhotoManager.getAssetPathList
      // throwing) must not look identical to "scanned fine, found zero
      // duplicates". Swallowing it here previously meant the caller
      // treated a FAILED scan as a completed one: it built zero groups,
      // showed "No duplicates found", and cleared the resume checkpoint
      // on the way out -- silently discarding any real hashing progress
      // from an interrupted run. Per-photo failures (a single unreadable
      // thumbnail, a missing asset) are already handled gracefully inside
      // _fetchMetadata/_computeHash and never reach this catch; only
      // failures affecting the scan as a whole do.
      debugPrint('[PhotoScanner] ERROR: $e');
      debugPrint('[PhotoScanner] StackTrace: $stackTrace');
      rethrow;
    }
  }

  /// Fetches just enough to sort/cluster and display a photo: creation
  /// time and file size. No thumbnail, no hash -- this is the cheap Phase 1
  /// step, always run for every photo.
  static Future<PhotoItem> _fetchMetadata(AssetEntity asset) async {
    // createDateTime is non-nullable in the installed photo_manager
    // version -- no `?? DateTime.now()` fallback needed or possible.
    final createDateTime = asset.createDateTime;

    try {
      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: createDateTime,
        fileSize: await asset.fileSize,
      );
    } catch (e) {
      debugPrint('[PhotoScanner] Error fetching metadata for ${asset.id}: $e');
      return PhotoItem(
        id: asset.id,
        path: asset.relativePath ?? 'Unknown',
        createDateTime: createDateTime,
        fileSize: 0,
      );
    }
  }

  /// Fetches a thumbnail and computes its dHash. This is the expensive
  /// Phase 2 step, only run for photos that share a time cluster with at
  /// least one other photo.
  static Future<String?> _computeHash(AssetEntity asset) async {
    try {
      final Uint8List? thumbData = await asset.thumbnailDataWithSize(
        const ThumbnailSize(200, 200),
      );
      if (thumbData == null) return null;
      return SimilarityService.computeDHash(thumbData);
    } catch (e) {
      debugPrint('Error computing hash for ${asset.id}: $e');
      return null;
    }
  }
}
