import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/models/photo_group.dart';
import 'package:dupesweep/models/photo_item.dart';

PhotoItem _photo(
  String id, {
  int fileSize = 1000,
  bool isSelected = false,
  bool isBest = false,
}) =>
    PhotoItem(
      id: id,
      path: 'path_$id',
      createDateTime: DateTime(2024, 1, 1),
      fileSize: fileSize,
      isSelected: isSelected,
      isBest: isBest,
    );

void main() {
  group('PhotoGroup.totalSize', () {
    test('sums fileSize across all photos regardless of selection', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [
          _photo('a', fileSize: 100),
          _photo('b', fileSize: 250, isSelected: true),
          _photo('c', fileSize: 50),
        ],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(group.totalSize, 400);
    });

    test('is 0 for an empty photo list', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(group.totalSize, 0);
    });
  });

  group('PhotoGroup.selectedCount', () {
    test('counts only selected photos', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [
          _photo('a', isSelected: true),
          _photo('b'),
          _photo('c', isSelected: true),
        ],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(group.selectedCount, 2);
    });
  });

  group('PhotoGroup.deleteCount / reclaimableBytes', () {
    // Recent, intentional behavior change: deleteCount/reclaimableBytes no
    // longer exclude isBest photos -- isBest is only a heuristic the user
    // can override, including deleting every photo in a group (see
    // photo_group.dart comment above `deleteCount`). These tests lock in
    // that current behavior.
    test('counts a selected isBest photo, not just non-best selections', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [
          _photo('a', fileSize: 500, isSelected: true, isBest: true),
          _photo('b', fileSize: 300, isSelected: true),
          _photo('c', fileSize: 200),
        ],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(group.deleteCount, 2);
      expect(group.reclaimableBytes, 800);
    });

    test('is 0 when nothing is selected, even if isBest is set', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [
          _photo('a', fileSize: 500, isBest: true),
          _photo('b', fileSize: 300),
        ],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(group.deleteCount, 0);
      expect(group.reclaimableBytes, 0);
    });

    test('counts every photo when the whole group is selected', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [
          _photo('a', fileSize: 500, isSelected: true, isBest: true),
          _photo('b', fileSize: 300, isSelected: true),
          _photo('c', fileSize: 200, isSelected: true),
        ],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(group.deleteCount, 3);
      expect(group.reclaimableBytes, 1000);
    });
  });

  group('PhotoGroup.selectAllNonBest', () {
    test('selects every photo except the one flagged isBest', () {
      final a = _photo('a', isBest: true);
      final b = _photo('b');
      final c = _photo('c');
      final group = PhotoGroup(
        id: 'g1',
        photos: [a, b, c],
        timestamp: DateTime(2024, 1, 1),
      );

      group.selectAllNonBest();

      expect(a.isSelected, isFalse);
      expect(b.isSelected, isTrue);
      expect(c.isSelected, isTrue);
    });

    test('selects everyone when no photo is flagged isBest', () {
      final a = _photo('a');
      final b = _photo('b');
      final group = PhotoGroup(
        id: 'g1',
        photos: [a, b],
        timestamp: DateTime(2024, 1, 1),
      );

      group.selectAllNonBest();

      expect(a.isSelected, isTrue);
      expect(b.isSelected, isTrue);
    });

    test('does not touch an already-selected isBest photo', () {
      // isBest photos are never selected by this method, but if some other
      // code path already selected one, selectAllNonBest should leave it
      // alone rather than deselecting it.
      final a = _photo('a', isBest: true, isSelected: true);
      final group = PhotoGroup(
        id: 'g1',
        photos: [a],
        timestamp: DateTime(2024, 1, 1),
      );

      group.selectAllNonBest();

      expect(a.isSelected, isTrue);
    });
  });

  group('PhotoGroup.ensureBestElected', () {
    test('does nothing when a photo is already flagged isBest', () {
      final a = _photo('a', fileSize: 100, isBest: true);
      final b = _photo('b', fileSize: 900);
      final group = PhotoGroup(
        id: 'g1',
        photos: [a, b],
        timestamp: DateTime(2024, 1, 1),
      );

      group.ensureBestElected();

      // The larger file (b) is NOT promoted over the existing pick -- an
      // existing isBest flag always wins, this only fills a gap.
      expect(a.isBest, isTrue);
      expect(b.isBest, isFalse);
    });

    test(
        'elects the largest-file-size photo when none is flagged isBest '
        '(regression: this is what removeDeletedPhotos calls after a '
        'group loses its isBest photo to deletion, so a group is never '
        'left with no keeper spared)', () {
      final a = _photo('a', fileSize: 300);
      final b = _photo('b', fileSize: 900);
      final c = _photo('c', fileSize: 500);
      final group = PhotoGroup(
        id: 'g1',
        photos: [a, b, c],
        timestamp: DateTime(2024, 1, 1),
      );

      group.ensureBestElected();

      expect(b.isBest, isTrue);
      expect(a.isBest, isFalse);
      expect(c.isBest, isFalse);
    });

    test('is a no-op for an empty photo list', () {
      final group = PhotoGroup(
        id: 'g1',
        photos: [],
        timestamp: DateTime(2024, 1, 1),
      );

      expect(() => group.ensureBestElected(), returnsNormally);
    });
  });

  group('PhotoGroup.deselectAll', () {
    test('clears isSelected on every photo, including isBest ones', () {
      final a = _photo('a', isSelected: true, isBest: true);
      final b = _photo('b', isSelected: true);
      final c = _photo('c');
      final group = PhotoGroup(
        id: 'g1',
        photos: [a, b, c],
        timestamp: DateTime(2024, 1, 1),
      );

      group.deselectAll();

      expect(a.isSelected, isFalse);
      expect(b.isSelected, isFalse);
      expect(c.isSelected, isFalse);
    });
  });
}
