import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';
import 'similarity_service.dart';

class PhotoScannerService {
  static Future<List<PhotoItem>> scanAllPhotos({
    Function(int, int)? onProgress,
  }) async {
    try {
      print('[PhotoScanner] Starting scan...');

      // Initialize background isolate for platform channels
      try {
        BackgroundIsolateBinaryMessenger.ensureInitialized(ServicesBinding.rootIsolateToken!);
        print('[PhotoScanner] BackgroundIsolate initialized');
      } catch (e) {
        print('[PhotoScanner] BackgroundIsolate already initialized or main thread: $e');
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
      final photos = <PhotoItem>[];

      for (int i = 0; i < allAssets.length; i++) {
        final asset = allAssets[i];
        final createDateTime = asset.createDateTime ?? DateTime.now();

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

        photos.add(PhotoItem(
          id: asset.id,
          path: asset.relativePath ?? 'Unknown',
          createDateTime: createDateTime,
          fileSize: await asset.fileSize,
          dhash: dhash,
        ));

        onProgress?.call(i + 1, allAssets.length);
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
}
