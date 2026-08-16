import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/models/photo_item.dart';
import 'package:dupesweep/services/flagged_photo_cache_service.dart';

PhotoItem _photo(
  String id, {
  int fileSize = 1000,
  bool isSelected = false,
  double? sharpnessScore,
  double? exposureScore,
}) =>
    PhotoItem(
      id: id,
      path: 'path_$id',
      createDateTime: DateTime(2024, 1, 1),
      fileSize: fileSize,
      isSelected: isSelected,
      sharpnessScore: sharpnessScore,
      exposureScore: exposureScore,
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('flagged_photo_cache_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('FlaggedPhotoCacheService.blurry', () {
    test('round-trips photos (including score fields) through save and load',
        () async {
      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      final photos = [
        _photo('a', sharpnessScore: 0.04, exposureScore: 0.92),
        _photo('b', fileSize: 300, isSelected: true),
      ];

      await service.save(photos);

      final reloaded =
          await FlaggedPhotoCacheService.blurry(directory: tempDir).load();

      expect(reloaded, isNotNull);
      expect(reloaded!.map((p) => p.id), ['a', 'b']);

      final a = reloaded.firstWhere((p) => p.id == 'a');
      expect(a.sharpnessScore, 0.04);
      expect(a.exposureScore, 0.92);

      final b = reloaded.firstWhere((p) => p.id == 'b');
      expect(b.fileSize, 300);
      expect(b.isSelected, isTrue);
    });

    test('load returns null when no cache file exists', () async {
      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      expect(await service.load(), isNull);
    });

    test('a later save overwrites the earlier saved list entirely', () async {
      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      await service.save([_photo('a'), _photo('b')]);
      await service.save([_photo('c')]);

      final reloaded =
          await FlaggedPhotoCacheService.blurry(directory: tempDir).load();
      expect(reloaded!.map((p) => p.id), ['c']);
    });

    test('saving an empty list makes load return null (nothing to resume)',
        () async {
      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      await service.save([_photo('a')]);
      await service.save([]);

      final reloaded =
          await FlaggedPhotoCacheService.blurry(directory: tempDir).load();
      expect(reloaded, isNull);
    });

    test('clear deletes the saved file so load returns null afterward',
        () async {
      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      await service.save([_photo('a')]);
      final file = File('${tempDir.path}/blurry_cache.json');
      expect(file.existsSync(), isTrue);

      await service.clear();

      expect(file.existsSync(), isFalse);
      expect(await service.load(), isNull);
    });

    test('corrupt (garbage bytes) cache file is treated as no saved list',
        () async {
      final file = File('${tempDir.path}/blurry_cache.json');
      await file.writeAsString('{not valid json');

      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      expect(await service.load(), isNull);
    });

    test('wrong schema version cache file is treated as no saved list',
        () async {
      final file = File('${tempDir.path}/blurry_cache.json');
      await file.writeAsString(jsonEncode({
        'version': 999,
        'photos': [
          {
            'id': 'a',
            'path': 'p',
            'createDateTimeMillis': 0,
            'fileSize': 1,
          },
        ],
      }));

      final service = FlaggedPhotoCacheService.blurry(directory: tempDir);
      expect(await service.load(), isNull);
    });
  });

  group('FlaggedPhotoCacheService.largeFiles', () {
    test('uses a separate cache file from .blurry', () async {
      final blurryService =
          FlaggedPhotoCacheService.blurry(directory: tempDir);
      final largeFilesService =
          FlaggedPhotoCacheService.largeFiles(directory: tempDir);

      await blurryService.save([_photo('a')]);
      await largeFilesService.save([_photo('b')]);

      final reloadedBlurry =
          await FlaggedPhotoCacheService.blurry(directory: tempDir).load();
      final reloadedLarge =
          await FlaggedPhotoCacheService.largeFiles(directory: tempDir)
              .load();

      expect(reloadedBlurry!.single.id, 'a');
      expect(reloadedLarge!.single.id, 'b');
    });

    test('round-trips photos through save and load', () async {
      final service = FlaggedPhotoCacheService.largeFiles(directory: tempDir);
      await service.save([_photo('a', fileSize: 50000000)]);

      final reloaded =
          await FlaggedPhotoCacheService.largeFiles(directory: tempDir)
              .load();

      expect(reloaded!.single.fileSize, 50000000);
    });
  });
}
