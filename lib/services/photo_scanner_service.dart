import 'package:photo_manager/photo_manager.dart';
import '../models/photo_item.dart';

class PhotoScannerService {
  static Future<List<PhotoItem>> scanAllPhotos({
    Function(int, int)? onProgress,
  }) async {
    try {
      final albums = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );

      if (albums.isEmpty) {
        return [];
      }

      final album = albums.first;
      final assetCount = await album.assetCountAsync;
      final allAssets = await album.getAssetListRange(
        start: 0,
        end: assetCount,
      );

      final photos = <PhotoItem>[];

      for (int i = 0; i < allAssets.length; i++) {
        final asset = allAssets[i];
        final createDateTime = asset.createDateTime ?? DateTime.now();

        photos.add(PhotoItem(
          id: asset.id,
          path: asset.relativePath ?? 'Unknown',
          createDateTime: createDateTime,
          fileSize: await asset.fileSize,
        ));

        onProgress?.call(i + 1, allAssets.length);
      }

      // Sort by create date
      photos.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));

      return photos;
    } catch (e) {
      print('Error scanning photos: $e');
      return [];
    }
  }
}
