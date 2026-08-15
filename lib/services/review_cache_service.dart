import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/photo_group.dart';
import '../models/photo_item.dart';

/// Schema version for the on-disk review list. Bumped only if the entry
/// shape changes; a mismatched version on load is treated as "no saved
/// list" rather than attempting a lossy migration.
const int _kReviewCacheVersion = 1;
const String _kReviewCacheFileName = 'review_cache.json';

/// Durable snapshot of `AppStateProvider.photoGroups` -- the *finished*
/// grouped review result, as opposed to `ScanCacheService` which only
/// bridges an *in-progress* scan's hashing work. Lets the app skip a full
/// rescan on next launch and drop the user straight back into reviewing
/// where they left off.
///
/// Same write-temp-then-rename pattern as `ScanCacheService` so a kill
/// mid-write can never leave a half-written `review_cache.json` behind.
class ReviewCacheService {
  /// Directory the cache file lives in. Injectable for testability;
  /// defaults to the platform app-support directory in production.
  final Directory? _injectedDirectory;

  ReviewCacheService({Directory? directory}) : _injectedDirectory = directory;

  Future<Directory> _resolveDirectory() async {
    if (_injectedDirectory != null) return _injectedDirectory!;
    return getApplicationSupportDirectory();
  }

  Future<File> _cacheFile() async {
    final dir = await _resolveDirectory();
    return File('${dir.path}/$_kReviewCacheFileName');
  }

  Future<File> _tempFile() async {
    final dir = await _resolveDirectory();
    return File('${dir.path}/$_kReviewCacheFileName.tmp');
  }

  /// Overwrites the saved review list with [groups]. Called after every
  /// scan completion and every delete, so the saved copy never points at
  /// photos that no longer exist. Failures are logged, never thrown -- a
  /// failed save just means next launch falls back to a full rescan.
  Future<void> save(List<PhotoGroup> groups) async {
    final payload = {
      'version': _kReviewCacheVersion,
      'groups': [for (final g in groups) _groupToJson(g)],
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
      debugPrint('[ReviewCache] Failed to save review list: $e');
    }
  }

  /// Loads the previously-saved review list. Returns `null` if none
  /// exists, it fails to parse, its version doesn't match, or it's empty
  /// (an empty saved list isn't worth resuming into -- it's simpler and
  /// safer to fall back to a fresh scan than to show an empty "resumed"
  /// review screen). Any parse failure is treated the same way -- logged,
  /// never thrown -- so a corrupt file can never crash app startup.
  Future<List<PhotoGroup>?> load() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null; // ignore: avoid_slow_async_io

      final contents = await file.readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) return null;

      final version = decoded['version'];
      if (version != _kReviewCacheVersion) return null;

      final groupsJson = decoded['groups'];
      if (groupsJson is! List) return null;

      final groups = <PhotoGroup>[];
      for (final g in groupsJson) {
        if (g is! Map<String, dynamic>) continue;
        try {
          final group = _groupFromJson(g);
          if (group.photos.isEmpty) continue;
          groups.add(group);
        } catch (e) {
          debugPrint('[ReviewCache] Skipping malformed group: $e');
        }
      }

      if (groups.isEmpty) return null;
      return groups;
    } catch (e) {
      debugPrint('[ReviewCache] Failed to load review list, ignoring: $e');
      return null;
    }
  }

  /// Deletes the saved review list, e.g. when the user starts a full
  /// rescan and it's about to be superseded anyway.
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
      debugPrint('[ReviewCache] Failed to clear review list: $e');
    }
  }

  Map<String, dynamic> _groupToJson(PhotoGroup g) => {
        'id': g.id,
        'groupType': g.groupType,
        'timestampMillis': g.timestamp.millisecondsSinceEpoch,
        'photos': [for (final p in g.photos) _photoToJson(p)],
      };

  PhotoGroup _groupFromJson(Map<String, dynamic> json) {
    final photosJson = json['photos'];
    final photos = <PhotoItem>[
      if (photosJson is List)
        for (final p in photosJson)
          if (p is Map<String, dynamic>) _photoFromJson(p),
    ];

    return PhotoGroup(
      id: json['id'] as String,
      groupType: json['groupType'] as String? ?? 'time',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestampMillis'] as int,
      ),
      photos: photos,
    );
  }

  Map<String, dynamic> _photoToJson(PhotoItem p) => {
        'id': p.id,
        'path': p.path,
        'createDateTimeMillis': p.createDateTime.millisecondsSinceEpoch,
        'fileSize': p.fileSize,
        'dhash': p.dhash,
        'isBest': p.isBest,
        'isSelected': p.isSelected,
      };

  PhotoItem _photoFromJson(Map<String, dynamic> json) => PhotoItem(
        id: json['id'] as String,
        path: json['path'] as String? ?? 'Unknown',
        createDateTime: DateTime.fromMillisecondsSinceEpoch(
          json['createDateTimeMillis'] as int,
        ),
        fileSize: json['fileSize'] as int? ?? 0,
        dhash: json['dhash'] as String?,
        isBest: json['isBest'] as bool? ?? false,
        isSelected: json['isSelected'] as bool? ?? false,
      );
}
