import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/main.dart';
import 'package:dupesweep/models/photo_group.dart';
import 'package:dupesweep/models/photo_item.dart';
import 'package:dupesweep/services/review_cache_service.dart';

PhotoItem _photo(String id, {int fileSize = 1000, bool isBest = false}) =>
    PhotoItem(
      id: id,
      path: 'path_$id',
      createDateTime: DateTime(2024, 1, 1),
      fileSize: fileSize,
      isBest: isBest,
    );

void main() {
  group('AppStateProvider.startScan', () {
    test('sets isScanning true and resets progress to 0', () {
      final provider = AppStateProvider();
      provider.scanProgress = 0.75;

      provider.startScan();

      expect(provider.isScanning, isTrue);
      expect(provider.scanProgress, 0.0);
    });

    test('notifies listeners', () {
      final provider = AppStateProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.startScan();

      expect(notified, isTrue);
    });
  });

  group('AppStateProvider.updateProgress', () {
    test('sets scanProgress and scanStatus', () {
      final provider = AppStateProvider();

      provider.updateProgress(0.42, 'Hashing photos...');

      expect(provider.scanProgress, 0.42);
      expect(provider.scanStatus, 'Hashing photos...');
    });

    test('notifies listeners', () {
      final provider = AppStateProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.updateProgress(0.5, 'Scanning...');

      expect(notified, isTrue);
    });
  });

  group('AppStateProvider.finishScan', () {
    test('sets photoGroups and clears isScanning', () {
      final provider = AppStateProvider();
      provider.isScanning = true;
      final groups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.finishScan(groups);

      expect(provider.photoGroups, groups);
      expect(provider.isScanning, isFalse);
    });

    test('notifies listeners', () {
      final provider = AppStateProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.finishScan([]);

      expect(notified, isTrue);
    });
  });

  group('AppStateProvider.cancelScan', () {
    test('clears isScanning without touching photoGroups', () {
      final provider = AppStateProvider();
      provider.isScanning = true;
      final existingGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];
      provider.photoGroups = existingGroups;

      provider.cancelScan();

      expect(provider.isScanning, isFalse);
      expect(provider.photoGroups, existingGroups);
    });

    test('notifies listeners', () {
      final provider = AppStateProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.cancelScan();

      expect(notified, isTrue);
    });
  });

  group('AppStateProvider.removeDeletedPhotos', () {
    test('removes only the deleted photos from each group', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b'), _photo('c')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.removeDeletedPhotos({'b'});

      expect(provider.photoGroups.single.photos.map((p) => p.id), ['a', 'c']);
    });

    test('drops a group that is left with 1 or 0 photos', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g2',
          photos: [_photo('c'), _photo('d'), _photo('e')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      // g1 loses one of its two photos -- nothing left to compare, so the
      // whole group should disappear, not linger as a singleton.
      provider.removeDeletedPhotos({'b'});

      expect(provider.photoGroups.length, 1);
      expect(provider.photoGroups.single.id, 'g2');
    });

    test('notifies listeners when photos are removed', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      var notified = false;
      provider.addListener(() => notified = true);

      provider.removeDeletedPhotos({'a'});

      expect(notified, isTrue);
    });

    test('is a no-op for an empty deleted-id set', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      var notified = false;
      provider.addListener(() => notified = true);

      provider.removeDeletedPhotos({});

      expect(notified, isFalse);
      expect(provider.photoGroups.single.photos.length, 2);
    });

    test(
        're-elects a best photo for a group that loses its isBest photo '
        '(regression: without this, a group whose BEST-marked photo gets '
        'deleted has no keeper spared, so "Select All Non-Best" would '
        'select every remaining photo)', () {
      final best = _photo('a', fileSize: 900, isBest: true);
      final b = _photo('b', fileSize: 300);
      final c = _photo('c', fileSize: 500);
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [best, b, c],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.removeDeletedPhotos({'a'});

      final survivors = provider.photoGroups.single.photos;
      expect(survivors.map((p) => p.id), containsAll(['b', 'c']));
      expect(survivors.where((p) => p.isBest).length, 1);
      // Largest remaining file (c, 500) is the new pick.
      expect(survivors.firstWhere((p) => p.id == 'c').isBest, isTrue);
    });

    test('leaves the existing isBest photo alone when it survives deletion',
        () {
      final best = _photo('a', fileSize: 900, isBest: true);
      final b = _photo('b', fileSize: 300);
      final c = _photo('c', fileSize: 500);
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [best, b, c],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.removeDeletedPhotos({'c'});

      final survivors = provider.photoGroups.single.photos;
      expect(survivors.where((p) => p.isBest).length, 1);
      expect(survivors.firstWhere((p) => p.id == 'a').isBest, isTrue);
    });

    test(
        'sets pendingExpandGroupId to the previous surviving group when a '
        'group is removed (so the review screen can auto-expand it and '
        'the user picks up where they were reviewing)', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g2',
          photos: [_photo('c'), _photo('d')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g3',
          photos: [_photo('e'), _photo('f')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      // g2 loses one of its two photos and disappears; g1 (immediately
      // before it) is the neighbor that should get expanded.
      provider.removeDeletedPhotos({'c'});

      expect(provider.photoGroups.map((g) => g.id), ['g1', 'g3']);
      expect(provider.pendingExpandGroupId, 'g1');
    });

    test(
        'pendingExpandGroupId is null when the removed group was first in '
        'the list (no previous group to expand)', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g2',
          photos: [_photo('c'), _photo('d')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.removeDeletedPhotos({'a'});

      expect(provider.photoGroups.map((g) => g.id), ['g2']);
      expect(provider.pendingExpandGroupId, isNull);
    });

    test(
        'pendingExpandGroupId points at the neighbor of the last removed '
        'group when several groups disappear in one delete', () {
      final provider = AppStateProvider();
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g2',
          photos: [_photo('c'), _photo('d')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g3',
          photos: [_photo('e'), _photo('f')],
          timestamp: DateTime(2024, 1, 1),
        ),
        PhotoGroup(
          id: 'g4',
          photos: [_photo('g'), _photo('h')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      // g2 and g3 both disappear; g1 is the neighbor of the last
      // (bottom-most) one, g3.
      provider.removeDeletedPhotos({'c', 'e'});

      expect(provider.photoGroups.map((g) => g.id), ['g1', 'g4']);
      expect(provider.pendingExpandGroupId, 'g1');
    });
  });

  group('AppStateProvider review-cache persistence', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('app_state_review_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('finishScan persists the review list for a later launch to resume',
        () async {
      final reviewCache = ReviewCacheService(directory: tempDir);
      final provider = AppStateProvider(reviewCache: reviewCache);
      final groups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.finishScan(groups);
      // finishScan fires the save off without awaiting it (see main.dart) --
      // await the debug-only hook so the background write has actually
      // landed on disk before asserting against it.
      await provider.debugLastReviewSave;

      final reloaded = await ReviewCacheService(directory: tempDir).load();
      expect(reloaded, isNotNull);
      expect(reloaded!.single.id, 'g1');
      expect(reloaded.single.photos.map((p) => p.id), ['a', 'b']);
    });

    test(
        'removeDeletedPhotos re-saves the review list so a later launch '
        'never resumes into already-deleted photos', () async {
      final reviewCache = ReviewCacheService(directory: tempDir);
      final provider = AppStateProvider(reviewCache: reviewCache);
      provider.photoGroups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b'), _photo('c')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.removeDeletedPhotos({'b'});
      await provider.debugLastReviewSave;

      final reloaded = await ReviewCacheService(directory: tempDir).load();
      expect(reloaded, isNotNull);
      expect(reloaded!.single.photos.map((p) => p.id), ['a', 'c']);
    });

    test('loadSavedReview sets photoGroups and clears isScanning', () {
      final provider = AppStateProvider(
        reviewCache: ReviewCacheService(directory: tempDir),
      );
      provider.isScanning = true;
      final groups = [
        PhotoGroup(
          id: 'g1',
          photos: [_photo('a'), _photo('b')],
          timestamp: DateTime(2024, 1, 1),
        ),
      ];

      provider.loadSavedReview(groups);

      expect(provider.photoGroups, groups);
      expect(provider.isScanning, isFalse);
    });

    test('loadSavedReview notifies listeners', () {
      final provider = AppStateProvider(
        reviewCache: ReviewCacheService(directory: tempDir),
      );
      var notified = false;
      provider.addListener(() => notified = true);

      provider.loadSavedReview([]);

      expect(notified, isTrue);
    });
  });
}
