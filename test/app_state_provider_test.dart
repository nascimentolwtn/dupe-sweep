import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/main.dart';
import 'package:dupesweep/models/photo_group.dart';
import 'package:dupesweep/models/photo_item.dart';

PhotoItem _photo(String id, {int fileSize = 1000}) => PhotoItem(
      id: id,
      path: 'path_$id',
      createDateTime: DateTime(2024, 1, 1),
      fileSize: fileSize,
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
  });
}
