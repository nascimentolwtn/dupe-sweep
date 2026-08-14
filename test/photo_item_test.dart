import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/models/photo_item.dart';

PhotoItem _photo({
  String id = 'a',
  int fileSize = 1000,
  double? sharpnessScore,
  double? exposureScore,
}) =>
    PhotoItem(
      id: id,
      path: 'path_$id',
      createDateTime: DateTime(2024, 1, 1),
      fileSize: fileSize,
      sharpnessScore: sharpnessScore,
      exposureScore: exposureScore,
    );

void main() {
  group('PhotoItem.overallScore', () {
    test('weights sharpness at 0.6 and exposure at 0.4', () {
      final photo = _photo(sharpnessScore: 10.0, exposureScore: 5.0);

      expect(photo.overallScore, closeTo(10.0 * 0.6 + 5.0 * 0.4, 1e-9));
    });

    test('is 0 when neither score is set', () {
      final photo = _photo();

      expect(photo.overallScore, 0.0);
    });

    test('counts only the sharpness contribution when exposure is null', () {
      final photo = _photo(sharpnessScore: 10.0);

      expect(photo.overallScore, closeTo(6.0, 1e-9));
    });

    test('counts only the exposure contribution when sharpness is null', () {
      final photo = _photo(exposureScore: 10.0);

      expect(photo.overallScore, closeTo(4.0, 1e-9));
    });
  });

  group('PhotoItem.copyWith', () {
    test('returns an identical copy when no fields are overridden', () {
      final original = PhotoItem(
        id: 'a',
        path: 'path_a',
        createDateTime: DateTime(2024, 1, 1),
        fileSize: 1000,
        dhash: 'abc123',
        sharpnessScore: 1.5,
        exposureScore: 2.5,
        isSelected: true,
        isBest: true,
      );

      final copy = original.copyWith();

      expect(copy.id, original.id);
      expect(copy.path, original.path);
      expect(copy.createDateTime, original.createDateTime);
      expect(copy.fileSize, original.fileSize);
      expect(copy.dhash, original.dhash);
      expect(copy.sharpnessScore, original.sharpnessScore);
      expect(copy.exposureScore, original.exposureScore);
      expect(copy.isSelected, original.isSelected);
      expect(copy.isBest, original.isBest);
    });

    test('overrides only the fields explicitly passed', () {
      final original = _photo(id: 'a', fileSize: 1000);

      final copy = original.copyWith(fileSize: 2000, isSelected: true);

      expect(copy.id, 'a');
      expect(copy.fileSize, 2000);
      expect(copy.isSelected, isTrue);
      expect(copy.isBest, original.isBest);
    });

    test('does not mutate the original instance', () {
      final original = _photo(id: 'a', fileSize: 1000);

      original.copyWith(fileSize: 2000);

      expect(original.fileSize, 1000);
    });

    test('explicitly passing false for a bool field overrides a true original',
        () {
      // `isSelected ?? this.isSelected` only falls back to the original
      // when the argument is null; `false` is a real, non-null value, so
      // it takes effect as expected here.
      final original = _photo(id: 'a');
      original.isSelected = true;

      final copy = original.copyWith(isSelected: false);

      expect(copy.isSelected, isFalse);
    });
  });
}
