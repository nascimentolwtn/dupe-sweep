import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/photo_item.dart';

/// Schema version for the on-disk flat photo list. Bumped only if the
/// entry shape changes; a mismatched version on load is treated as "no
/// saved list" rather than attempting a lossy migration.
const int _kFlaggedPhotoCacheVersion = 1;

/// Durable snapshot of `AppStateProvider.blurryPhotos`/`.largeFiles` -- the
/// flat, independently-flagged results `BlurScanService`/
/// `LargeFileScanService` produce, as opposed to `ReviewCacheService`
/// which persists the grouped duplicate-scan result. Same
/// write-temp-then-rename durability and "resume instead of forcing a
/// rescan on next launch" purpose, just for the flat list shape these two
/// scan modes use instead of `PhotoGroup`s.
///
/// Two named constructors rather than one taking an arbitrary file name:
/// blurry and large-file results are never mixed, so there's no case
/// where a caller should be free to pick any file name -- fixing the two
/// valid file names here means `AppStateProvider` and `HomeScreen` can't
/// accidentally drift onto different file names for the same purpose.
class FlaggedPhotoCacheService {
  final String _fileName;
  final Directory? _injectedDirectory;

  FlaggedPhotoCacheService.blurry({Directory? directory})
      : _fileName = 'blurry_cache.json',
        _injectedDirectory = directory;

  FlaggedPhotoCacheService.largeFiles({Directory? directory})
      : _fileName = 'large_files_cache.json',
        _injectedDirectory = directory;

  Future<Directory> _resolveDirectory() async {
    if (_injectedDirectory != null) return _injectedDirectory!;
    return getApplicationSupportDirectory();
  }

  Future<File> _cacheFile() async {
    final dir = await _resolveDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<File> _tempFile() async {
    final dir = await _resolveDirectory();
    return File('${dir.path}/$_fileName.tmp');
  }

  /// Overwrites the saved list with [photos]. Called after every scan
  /// completion and every delete, so the saved copy never points at
  /// photos that no longer exist. Failures are logged, never thrown -- a
  /// failed save just means next launch falls back to a full rescan.
  Future<void> save(List<PhotoItem> photos) async {
    final payload = {
      'version': _kFlaggedPhotoCacheVersion,
      'photos': [for (final p in photos) _photoToJson(p)],
    };

    try {
      final dir = await _resolveDirectory();
      // ignore: avoid_slow_async_io
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final tempFile = await _tempFile();
      await tempFile.writeAsString(jsonEncode(payload), flush: true);

      final targetFile = await _cacheFile();
      await tempFile.rename(targetFile.path);
    } catch (e) {
      debugPrint('[FlaggedPhotoCache:$_fileName] Failed to save: $e');
    }
  }

  /// Loads the previously-saved list. Returns `null` if none exists, it
  /// fails to parse, its version doesn't match, or it's empty (an empty
  /// saved list isn't worth resuming into -- it's simpler and safer to
  /// fall back to a fresh scan than to show an empty "resumed" review
  /// screen). Any parse failure is treated the same way -- logged, never
  /// thrown -- so a corrupt file can never crash app startup.
  Future<List<PhotoItem>?> load() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null; // ignore: avoid_slow_async_io

      final contents = await file.readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) return null;

      final version = decoded['version'];
      if (version != _kFlaggedPhotoCacheVersion) return null;

      final photosJson = decoded['photos'];
      if (photosJson is! List) return null;

      final photos = <PhotoItem>[];
      for (final p in photosJson) {
        if (p is! Map<String, dynamic>) continue;
        try {
          photos.add(_photoFromJson(p));
        } catch (e) {
          debugPrint('[FlaggedPhotoCache:$_fileName] Skipping malformed '
              'photo: $e');
        }
      }

      if (photos.isEmpty) return null;
      return photos;
    } catch (e) {
      debugPrint('[FlaggedPhotoCache:$_fileName] Failed to load, '
          'ignoring: $e');
      return null;
    }
  }

  /// Deletes the saved list, e.g. when the user starts a full rescan and
  /// it's about to be superseded anyway.
  Future<void> clear() async {
    try {
      final file = await _cacheFile();
      // ignore: avoid_slow_async_io
      if (await file.exists()) {
        await file.delete();
      }
      final tempFile = await _tempFile();
      // ignore: avoid_slow_async_io
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (e) {
      debugPrint('[FlaggedPhotoCache:$_fileName] Failed to clear: $e');
    }
  }

  Map<String, dynamic> _photoToJson(PhotoItem p) => {
        'id': p.id,
        'path': p.path,
        'createDateTimeMillis': p.createDateTime.millisecondsSinceEpoch,
        'fileSize': p.fileSize,
        'sharpnessScore': p.sharpnessScore,
        'exposureScore': p.exposureScore,
        'isSelected': p.isSelected,
      };

  PhotoItem _photoFromJson(Map<String, dynamic> json) => PhotoItem(
        id: json['id'] as String,
        path: json['path'] as String? ?? 'Unknown',
        createDateTime: DateTime.fromMillisecondsSinceEpoch(
          json['createDateTimeMillis'] as int,
        ),
        fileSize: json['fileSize'] as int? ?? 0,
        sharpnessScore: (json['sharpnessScore'] as num?)?.toDouble(),
        exposureScore: (json['exposureScore'] as num?)?.toDouble(),
        isSelected: json['isSelected'] as bool? ?? false,
      );
}
