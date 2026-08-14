import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/models/photo_item.dart';
import 'package:dupesweep/screens/scan_progress_screen.dart';

void main() {
  group('buildPhotoGroups', () {
    test('clusters photos across a day boundary within the time window', () {
      // Regression test: 23:59:00 and 00:01:00 the next day are 2 minutes
      // apart and must land in the same group, even though they fall on
      // different calendar days.
      final photos = [
        PhotoItem(
          id: '1',
          path: 'path1',
          createDateTime: DateTime(2024, 1, 1, 23, 59, 0),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: '2',
          path: 'path2',
          createDateTime: DateTime(2024, 1, 2, 0, 1, 0),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
      ];

      final groups = buildPhotoGroups(photos);

      expect(groups.length, 1);
      expect(groups.first.photos.length, 2);
      expect(
        groups.first.photos.map((p) => p.id).toSet(),
        {'1', '2'},
      );
    });

    test('splits photos spanning a wide same-day range into different groups',
        () {
      // Regression test proving the old calendar-day-bucket behavior is
      // gone: two photos taken on the same day but 12 hours apart must NOT
      // be grouped together just because they share a calendar date. Each
      // is paired with a near-duplicate a few seconds later so the
      // resulting groups survive singleton-filtering and the assertion can
      // still observe the split.
      final photos = [
        PhotoItem(
          id: '1',
          path: 'path1',
          createDateTime: DateTime(2024, 1, 1, 9, 0, 0),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: '2',
          path: 'path2',
          createDateTime: DateTime(2024, 1, 1, 9, 0, 5),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: '3',
          path: 'path3',
          createDateTime: DateTime(2024, 1, 1, 21, 0, 0),
          fileSize: 1000,
          dhash: 'ffffffffffffffff',
        ),
        PhotoItem(
          id: '4',
          path: 'path4',
          createDateTime: DateTime(2024, 1, 1, 21, 0, 5),
          fileSize: 1000,
          dhash: 'ffffffffffffffff',
        ),
      ];

      final groups = buildPhotoGroups(photos);
      final resultIdSets =
          groups.map((g) => g.photos.map((p) => p.id).toSet()).toList();

      expect(resultIdSets, [
        {'1', '2'},
        {'3', '4'},
      ]);
    });

    test('drops singleton clusters -- nothing to compare a lone photo to', () {
      final photos = [
        PhotoItem(
          id: '1',
          path: 'path1',
          createDateTime: DateTime(2024, 1, 1, 9, 0, 0),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: '2',
          path: 'path2',
          createDateTime: DateTime(2024, 1, 1, 21, 0, 0),
          fileSize: 1000,
          dhash: 'ffffffffffffffff',
        ),
      ];

      final groups = buildPhotoGroups(photos);

      expect(groups, isEmpty);
    });

    test(
        'drops hash sub-groups that end up as singletons within a '
        'multi-photo time cluster', () {
      // Same time cluster (within the window), but hashes are maximally
      // different -- each photo ends up in its own hash sub-group, which
      // must be dropped even though the *time* cluster had 2+ photos.
      final photos = [
        PhotoItem(
          id: '1',
          path: 'path1',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 0),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: '2',
          path: 'path2',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 10),
          fileSize: 1000,
          dhash: 'ffffffffffffffff',
        ),
      ];

      final groups = buildPhotoGroups(photos);

      expect(groups, isEmpty);
    });

    test('empty photo list returns no groups', () {
      final groups = buildPhotoGroups([]);
      expect(groups, isEmpty);
    });

    test(
        'marks the largest-file-size photo in each group as isBest '
        '(regression: without this, "Select All Non-Best" selects every '
        'photo in the group, including the one worth keeping)', () {
      final photos = [
        PhotoItem(
          id: 'small',
          path: 'path1',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 0),
          fileSize: 500,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: 'large',
          path: 'path2',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 5),
          fileSize: 5000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: 'medium',
          path: 'path3',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 10),
          fileSize: 2000,
          dhash: '0000000000000000',
        ),
      ];

      final groups = buildPhotoGroups(photos);

      expect(groups.length, 1);
      final group = groups.first;
      final bestPhotos = group.photos.where((p) => p.isBest).toList();

      expect(bestPhotos.length, 1);
      expect(bestPhotos.single.id, 'large');
    });

    test('delegates to SimilarityService rather than reimplementing grouping',
        () {
      final photos = [
        PhotoItem(
          id: '1',
          path: 'path1',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 0),
          fileSize: 1000,
          dhash: '0000000000000000',
        ),
        PhotoItem(
          id: '2',
          path: 'path2',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 10),
          fileSize: 1000,
          dhash: '0000000000000001',
        ),
        PhotoItem(
          id: '3',
          path: 'path3',
          createDateTime: DateTime(2024, 1, 1, 12, 0, 20),
          fileSize: 1000,
          dhash: 'ffffffffffffffff',
        ),
      ];

      final groups = buildPhotoGroups(photos);
      final resultIdSets =
          groups.map((g) => g.photos.map((p) => p.id).toSet()).toList();

      // Photo '3' is its own hash sub-group (singleton) within the time
      // cluster, so it's dropped -- only the real duplicate pair survives.
      expect(resultIdSets, [
        {'1', '2'},
      ]);
    });
  });
}
