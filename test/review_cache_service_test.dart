import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/models/photo_group.dart';
import 'package:dupesweep/models/photo_item.dart';
import 'package:dupesweep/services/review_cache_service.dart';

PhotoItem _photo(
  String id, {
  int fileSize = 1000,
  bool isBest = false,
  bool isSelected = false,
  String? dhash,
}) =>
    PhotoItem(
      id: id,
      path: 'path_$id',
      createDateTime: DateTime(2024, 1, 1),
      fileSize: fileSize,
      isBest: isBest,
      isSelected: isSelected,
      dhash: dhash,
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('review_cache_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ReviewCacheService', () {
    test('round-trips groups (including photo fields) through save and load',
        () async {
      final service = ReviewCacheService(directory: tempDir);
      final groups = [
        PhotoGroup(
          id: 'g1',
          groupType: 'hash',
          timestamp: DateTime(2024, 3, 5, 12, 30),
          photos: [
            _photo('a', fileSize: 900, isBest: true, dhash: 'h1'),
            _photo('b', fileSize: 300, isSelected: true),
          ],
        ),
      ];

      await service.save(groups);

      final reloaded = await ReviewCacheService(directory: tempDir).load();

      expect(reloaded, isNotNull);
      expect(reloaded!.length, 1);
      final g = reloaded.single;
      expect(g.id, 'g1');
      expect(g.groupType, 'hash');
      expect(g.timestamp, DateTime(2024, 3, 5, 12, 30));
      expect(g.photos.map((p) => p.id), ['a', 'b']);

      final a = g.photos.firstWhere((p) => p.id == 'a');
      expect(a.fileSize, 900);
      expect(a.isBest, isTrue);
      expect(a.dhash, 'h1');

      final b = g.photos.firstWhere((p) => p.id == 'b');
      expect(b.isSelected, isTrue);
      expect(b.isBest, isFalse);
    });

    test('load returns null when no cache file exists', () async {
      final service = ReviewCacheService(directory: tempDir);
      final result = await service.load();
      expect(result, isNull);
    });

    test('a later save overwrites the earlier saved list entirely', () async {
      final service = ReviewCacheService(directory: tempDir);
      await service.save([
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ]);

      await service.save([
        PhotoGroup(
          id: 'g2',
          photos: [_photo('c'), _photo('d')],
          timestamp: DateTime(2024, 1, 2),
        ),
      ]);

      final reloaded = await ReviewCacheService(directory: tempDir).load();
      expect(reloaded!.map((g) => g.id), ['g2']);
    });

    test('saving an empty list makes load return null (nothing to resume)',
        () async {
      final service = ReviewCacheService(directory: tempDir);
      await service.save([
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ]);

      await service.save([]);

      final reloaded = await ReviewCacheService(directory: tempDir).load();
      expect(reloaded, isNull);
    });

    test('clear deletes the saved file so load returns null afterward',
        () async {
      final service = ReviewCacheService(directory: tempDir);
      await service.save([
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ]);
      final file = File('${tempDir.path}/review_cache.json');
      expect(file.existsSync(), isTrue);

      await service.clear();

      expect(file.existsSync(), isFalse);
      expect(await service.load(), isNull);
    });

    test('corrupt (garbage bytes) cache file is treated as no saved list',
        () async {
      final file = File('${tempDir.path}/review_cache.json');
      await file.writeAsString('{not valid json');

      final service = ReviewCacheService(directory: tempDir);
      final result = await service.load();

      expect(result, isNull);
    });

    test('wrong schema version cache file is treated as no saved list',
        () async {
      final file = File('${tempDir.path}/review_cache.json');
      await file.writeAsString(jsonEncode({
        'version': 999,
        'groups': [
          {
            'id': 'g1',
            'groupType': 'hash',
            'timestampMillis': 0,
            'photos': [
              {
                'id': 'a',
                'path': 'p',
                'createDateTimeMillis': 0,
                'fileSize': 1,
              },
            ],
          },
        ],
      }));

      final service = ReviewCacheService(directory: tempDir);
      final result = await service.load();

      expect(result, isNull);
    });

    test('a group left with zero photos after malformed entries is dropped',
        () async {
      final file = File('${tempDir.path}/review_cache.json');
      await file.writeAsString(jsonEncode({
        'version': 1,
        'groups': [
          {
            'id': 'g1',
            'groupType': 'hash',
            'timestampMillis': 0,
            'photos': <Object>[],
          },
          {
            'id': 'g2',
            'groupType': 'hash',
            'timestampMillis': 0,
            'photos': [
              {
                'id': 'a',
                'path': 'p',
                'createDateTimeMillis': 0,
                'fileSize': 1,
              },
            ],
          },
        ],
      }));

      final service = ReviewCacheService(directory: tempDir);
      final result = await service.load();

      expect(result, isNotNull);
      expect(result!.map((g) => g.id), ['g2']);
    });
  });
}
