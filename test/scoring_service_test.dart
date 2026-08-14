import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:dupesweep/services/scoring_service.dart';
import 'package:dupesweep/models/photo_item.dart';

/// Builds a small synthetic PNG in memory. [pixelFor] is called for every
/// (x, y) coordinate and must return a 0-255 grayscale value.
Uint8List _syntheticPng(
  int width,
  int height,
  int Function(int x, int y) pixelFor,
) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = pixelFor(x, y);
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return img.encodePng(image);
}

void main() {
  group('ScoringService', () {
    group('computeSharpness', () {
      test(
          'does not throw on a real decodable image '
          '(regression: _getGrayValue previously multiplied an already '
          '0-255 value by 255 again, and passed a raw int where the image '
          'package v4 API expects a Pixel -- neither compiled, let alone ran)',
          () {
        final bytes = _syntheticPng(200, 200, (x, y) => (x + y) % 256);

        expect(() => ScoringService.computeSharpness(bytes), returnsNormally);
      });

      test('returns 0.0 for a uniform (flat) image -- no edges to detect', () {
        final bytes = _syntheticPng(200, 200, (x, y) => 128);

        final score = ScoringService.computeSharpness(bytes);

        expect(score, 0.0);
      });

      test(
          'returns a higher score for a noisy/high-contrast image than a '
          'flat one', () {
        final flat = _syntheticPng(200, 200, (x, y) => 128);
        final checkerboard = _syntheticPng(
          200,
          200,
          (x, y) => (x + y).isEven ? 0 : 255,
        );

        final flatScore = ScoringService.computeSharpness(flat);
        final sharpScore = ScoringService.computeSharpness(checkerboard);

        expect(sharpScore, greaterThan(flatScore));
      });

      test('returns 0.0 for bytes that are not a decodable image', () {
        final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        expect(ScoringService.computeSharpness(bytes), 0.0);
      });
    });

    group('computeExposure', () {
      test(
          'does not throw, and stays within 0.0-1.0 '
          '(regression: histogram[value] with value up to 255*255 would '
          'throw RangeError on a 256-slot list before the _getGrayValue fix)',
          () {
        final bytes = _syntheticPng(100, 100, (x, y) => (x * 3) % 256);

        final score = ScoringService.computeExposure(bytes);

        expect(score, inInclusiveRange(0.0, 1.0));
      });

      test('scores a well-balanced mid-gray image near 1.0', () {
        final bytes = _syntheticPng(100, 100, (x, y) => 128);

        final score = ScoringService.computeExposure(bytes);

        expect(score, 1.0);
      });

      test('penalizes a mostly-black (underexposed) image', () {
        final bytes = _syntheticPng(100, 100, (x, y) => 5);

        final score = ScoringService.computeExposure(bytes);

        expect(score, lessThan(1.0));
      });

      test('penalizes a mostly-white (blown-out) image', () {
        final bytes = _syntheticPng(100, 100, (x, y) => 250);

        final score = ScoringService.computeExposure(bytes);

        expect(score, lessThan(1.0));
      });

      test('returns 0.5 for bytes that are not a decodable image', () {
        final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        expect(ScoringService.computeExposure(bytes), 0.5);
      });
    });

    group('rankByQuality', () {
      test('sorts descending by overallScore, highest first', () {
        final low = PhotoItem(
          id: 'low',
          path: 'p1',
          createDateTime: DateTime(2024, 1, 1),
          fileSize: 100,
          sharpnessScore: 0.1,
          exposureScore: 0.1,
        );
        final high = PhotoItem(
          id: 'high',
          path: 'p2',
          createDateTime: DateTime(2024, 1, 1),
          fileSize: 100,
          sharpnessScore: 0.9,
          exposureScore: 0.9,
        );
        final mid = PhotoItem(
          id: 'mid',
          path: 'p3',
          createDateTime: DateTime(2024, 1, 1),
          fileSize: 100,
          sharpnessScore: 0.5,
          exposureScore: 0.5,
        );

        final ranked = ScoringService.rankByQuality([low, high, mid]);

        expect(ranked.map((p) => p.id), ['high', 'mid', 'low']);
      });

      test('does not mutate the input list', () {
        final a = PhotoItem(
          id: 'a',
          path: 'p1',
          createDateTime: DateTime(2024, 1, 1),
          fileSize: 100,
          sharpnessScore: 0.1,
        );
        final b = PhotoItem(
          id: 'b',
          path: 'p2',
          createDateTime: DateTime(2024, 1, 1),
          fileSize: 100,
          sharpnessScore: 0.9,
        );
        final original = [a, b];

        ScoringService.rankByQuality(original);

        expect(original, [a, b]);
      });

      test('returns an empty list for an empty input', () {
        expect(ScoringService.rankByQuality([]), isEmpty);
      });
    });
  });
}
