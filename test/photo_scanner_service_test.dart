import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/models/photo_item.dart';
import 'package:dupesweep/services/photo_scanner_service.dart';

PhotoItem _photo(String id, DateTime time) => PhotoItem(
      id: id,
      path: 'path$id',
      createDateTime: time,
      fileSize: 1000,
    );

void main() {
  group('comparePhotosByTimeThenId', () {
    test('orders by createDateTime when timestamps differ', () {
      final now = DateTime(2024, 1, 1, 12, 0, 0);
      final a = _photo('a', now);
      final b = _photo('b', now.add(const Duration(seconds: 30)));

      expect(comparePhotosByTimeThenId(a, b), lessThan(0));
      expect(comparePhotosByTimeThenId(b, a), greaterThan(0));
    });

    test(
        'breaks exact-timestamp ties by id, regardless of input order '
        '(regression: without this, two photos sharing a createDateTime -- '
        'burst shots, same-second captures, exactly the ones most likely '
        'to be duplicates -- sorted however the non-deterministic '
        'Future.wait completion order in scanAllPhotos happened to leave '
        'them, which could split a real duplicate pair into different '
        'time clusters on one scan but not another of the same library)',
        () {
      final now = DateTime(2024, 1, 1, 12, 0, 0);
      final a = _photo('a', now);
      final b = _photo('b', now);

      // The comparator must agree with itself regardless of which side
      // 'a' vs 'b' land on -- i.e. it must impose the SAME total order no
      // matter what order photos happened to be inserted into the map
      // upstream.
      final forward = [a, b]..sort(comparePhotosByTimeThenId);
      final reversed = [b, a]..sort(comparePhotosByTimeThenId);

      expect(forward.map((p) => p.id).toList(), ['a', 'b']);
      expect(reversed.map((p) => p.id).toList(), ['a', 'b']);
    });

    test('returns 0 for identical id and timestamp', () {
      final now = DateTime(2024, 1, 1, 12, 0, 0);
      final a = _photo('same', now);
      final b = _photo('same', now);

      expect(comparePhotosByTimeThenId(a, b), 0);
    });
  });
}
