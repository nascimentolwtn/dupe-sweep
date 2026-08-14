import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/services/scan_cache_service.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scan_cache_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ScanCacheService', () {
    test('round-trips entries through flush and a fresh load', () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();

      for (var i = 0; i < 5; i++) {
        service.recordProcessed(
          'asset_$i',
          CachedPhotoData(
            dhash: 'hash_$i',
            createDateTimeMillis: 1000 + i,
            fileSize: 100 + i,
          ),
        );
      }
      await service.flush();

      final reloaded = ScanCacheService(directory: tempDir);
      await reloaded.load();

      expect(reloaded.cachedEntries.length, 5);
      for (var i = 0; i < 5; i++) {
        final entry = reloaded.cachedEntries['asset_$i'];
        expect(entry, isNotNull);
        expect(entry!.dhash, 'hash_$i');
        expect(entry.createDateTimeMillis, 1000 + i);
        expect(entry.fileSize, 100 + i);
      }
    });

    test('resume semantics: missing set is exactly liveIds - cachedIds',
        () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();

      final cachedIds = {'a', 'b', 'c'};
      for (final id in cachedIds) {
        service.recordProcessed(
          id,
          const CachedPhotoData(
            dhash: 'h',
            createDateTimeMillis: 1,
            fileSize: 1,
          ),
        );
      }
      await service.flush();

      final reloaded = ScanCacheService(directory: tempDir);
      await reloaded.load();

      final liveIds = {'a', 'b', 'c', 'd', 'e'};
      final missing = liveIds
          .where((id) => !reloaded.cachedEntries.containsKey(id))
          .toSet();
      final alreadyCached =
          liveIds.where((id) => reloaded.cachedEntries.containsKey(id)).toSet();

      expect(missing, {'d', 'e'});
      expect(alreadyCached, cachedIds);
    });

    test('orphaned cache entries (deleted photos) are silently omitted',
        () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();

      service.recordProcessed(
        'still_here',
        const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
      );
      service.recordProcessed(
        'deleted_photo',
        const CachedPhotoData(createDateTimeMillis: 2, fileSize: 2),
      );
      await service.flush();

      final reloaded = ScanCacheService(directory: tempDir);
      await reloaded.load();

      // Reconstruction must always be driven off the live asset list
      // filtered by "id is in cache", never off the cache's key set
      // directly -- so an id no longer present on-device is never read
      // back out, and no exception is thrown.
      final liveIds = {'still_here'};
      final reconstructed = liveIds
          .where((id) => reloaded.cachedEntries.containsKey(id))
          .toList();

      expect(reconstructed, ['still_here']);
      expect(reloaded.cachedEntries.containsKey('deleted_photo'), isTrue,
          reason: 'orphan stays in the cache map itself (pruned only on next '
              'full rewrite) but must never be reconstructed for a live id');
    });

    test('corrupt (garbage bytes) cache file is treated as empty, not thrown',
        () async {
      final file = File('${tempDir.path}/scan_cache.json');
      await file.writeAsString('{not valid json');

      final service = ScanCacheService(directory: tempDir);
      await expectLater(service.load(), completes);

      expect(service.cachedEntries, isEmpty);
    });

    test('wrong schema version cache file is treated as empty', () async {
      final file = File('${tempDir.path}/scan_cache.json');
      await file.writeAsString(jsonEncode({
        'version': 999,
        'totalKnownAssets': 1,
        'updatedAtMillis': 0,
        'entries': {
          'a': {'dhash': 'x', 'createDateTimeMillis': 1, 'fileSize': 1},
        },
      }));

      final service = ScanCacheService(directory: tempDir);
      await service.load();

      expect(service.cachedEntries, isEmpty);
    });

    test('maybeCheckpoint does not write before the count threshold', () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      final file = File('${tempDir.path}/scan_cache.json');

      service.recordProcessed(
        'a',
        const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
      );
      await service.maybeCheckpoint(
        everyN: 5,
        everyDuration: const Duration(minutes: 5),
      );

      expect(await file.exists(), isFalse);
    });

    test('maybeCheckpoint writes once the count threshold is crossed',
        () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      final file = File('${tempDir.path}/scan_cache.json');

      for (var i = 0; i < 5; i++) {
        service.recordProcessed(
          'id_$i',
          const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
        );
      }
      await service.maybeCheckpoint(
        everyN: 5,
        everyDuration: const Duration(minutes: 5),
      );

      expect(await file.exists(), isTrue);
    });

    test('maybeCheckpoint writes once the duration threshold elapses',
        () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      final file = File('${tempDir.path}/scan_cache.json');

      service.recordProcessed(
        'a',
        const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
      );
      await Future.delayed(const Duration(milliseconds: 20));
      await service.maybeCheckpoint(
        everyN: 1000,
        everyDuration: const Duration(milliseconds: 10),
      );

      expect(await file.exists(), isTrue);
    });

    test(
        'concurrent flush calls do not throw and all entries survive '
        '(regression: real-device race where multiple in-flight scan '
        'batches each crossed the checkpoint threshold and called flush '
        'at once, racing on the shared .tmp file)', () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();

      for (var i = 0; i < 20; i++) {
        service.recordProcessed(
          'id_$i',
          CachedPhotoData(createDateTimeMillis: i, fileSize: i),
        );
      }

      // Simulate several concurrently-running scan-batch futures all
      // deciding to checkpoint in the same tick.
      await Future.wait([
        service.flush(),
        service.flush(),
        service.flush(),
        service.flush(),
      ]);

      final reloaded = ScanCacheService(directory: tempDir);
      await reloaded.load();
      expect(reloaded.cachedEntries.length, 20);
    });

    test('clear deletes the cache file and resets in-memory state', () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      service.recordProcessed(
        'a',
        const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
      );
      await service.flush();

      final file = File('${tempDir.path}/scan_cache.json');
      expect(await file.exists(), isTrue);

      await service.clear();

      expect(await file.exists(), isFalse);
      expect(service.cachedEntries, isEmpty);
    });

    test('peekSummary returns null when no cache exists', () async {
      final service = ScanCacheService(directory: tempDir);
      final summary = await service.peekSummary();
      expect(summary, isNull);
    });

    test('setTotalKnownAssets persists across a flush and fresh load',
        () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      service.setTotalKnownAssets(42);
      await service.flush();

      final reloaded = ScanCacheService(directory: tempDir);
      await reloaded.load();

      expect(reloaded.totalKnownAssets, 42);
    });

    test('cachedEntries is unmodifiable', () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      service.recordProcessed(
        'a',
        const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
      );

      expect(
        () => service.cachedEntries['b'] = const CachedPhotoData(
          createDateTimeMillis: 2,
          fileSize: 2,
        ),
        throwsUnsupportedError,
      );
    });

    test('peekSummary reports processed/total counts from a saved cache',
        () async {
      final service = ScanCacheService(directory: tempDir);
      await service.load();
      service.setTotalKnownAssets(10);
      for (var i = 0; i < 4; i++) {
        service.recordProcessed(
          'id_$i',
          const CachedPhotoData(createDateTimeMillis: 1, fileSize: 1),
        );
      }
      await service.flush();

      final fresh = ScanCacheService(directory: tempDir);
      final summary = await fresh.peekSummary();

      expect(summary, isNotNull);
      expect(summary!.processedCount, 4);
      expect(summary.totalKnownAssets, 10);
    });
  });
}
