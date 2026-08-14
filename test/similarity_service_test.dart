import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:dupesweep/services/similarity_service.dart';
import 'package:dupesweep/models/photo_item.dart';

/// Builds a small synthetic PNG in memory so [SimilarityService.computeDHash]
/// can be exercised without needing a real photo file. [pixelFor] is called
/// for every (x, y) coordinate and must return a 0-255 grayscale value.
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
  group('SimilarityService', () {
    group('computeDHash', () {
      test('returns a well-formed 16-hex-char hash for a valid image', () {
        final bytes = _syntheticPng(16, 16, (x, y) => (x * 16) % 256);

        final hash = SimilarityService.computeDHash(bytes);

        expect(hash.length, 16);
        expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(hash), isTrue);
      });

      test('is deterministic: same image bytes produce the same hash', () {
        final bytes = _syntheticPng(16, 16, (x, y) => (x * 16 + y) % 256);

        final hash1 = SimilarityService.computeDHash(bytes);
        final hash2 = SimilarityService.computeDHash(bytes);

        expect(hash1, hash2);
      });

      test(
          'a left-to-right ascending gradient and its mirror image produce '
          'different hashes', () {
        // Ascending gradient: each pixel brighter than the one to its left,
        // so every horizontal comparison bit is the same direction.
        final ascending = _syntheticPng(16, 16, (x, y) => (x * 16) % 256);
        // Mirrored (descending) gradient: every comparison flips relative
        // to the ascending version.
        final descending =
            _syntheticPng(16, 16, (x, y) => ((15 - x) * 16) % 256);

        final hashAscending = SimilarityService.computeDHash(ascending);
        final hashDescending = SimilarityService.computeDHash(descending);

        expect(hashAscending, isNot(equals(hashDescending)));
        expect(
          SimilarityService.hammingDistance(hashAscending, hashDescending),
          greaterThan(0),
        );
      });

      test('returns an empty string for bytes that are not a decodable image',
          () {
        final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        final hash = SimilarityService.computeDHash(bytes);

        expect(hash, '');
      });

      test(
          'a uniform solid-color image hashes to all zero bits '
          '(documents current behavior: dHash compares each pixel to its '
          'right neighbor, and a flat image has no neighbor differences)', () {
        final bytes = _syntheticPng(16, 16, (x, y) => 128);

        final hash = SimilarityService.computeDHash(bytes);

        expect(hash, '0000000000000000');
      });

      test(
          'never returns a sign-prefixed hash, even when the top bit is set '
          '(regression: hash is built as a signed 64-bit int via 64 '
          'left-shifts, so whichever comparison lands in the sign-bit '
          'position made toRadixString emit "-<magnitude>" instead of an '
          'unsigned hex string -- e.g. "-555555555555556" instead of '
          '"aaaaaaaaaaaaaaaa". A descending gradient (first pixel brighter '
          'than the second) sets exactly that bit.)', () {
        final descending =
            _syntheticPng(16, 16, (x, y) => ((15 - x) * 16) % 256);

        final hash = SimilarityService.computeDHash(descending);

        expect(
          RegExp(r'^[0-9a-f]{16}$').hasMatch(hash),
          isTrue,
          reason: 'got "$hash", which is not clean unsigned hex',
        );
        // The corrupted string previously broke hammingDistance's own
        // BigInt.parse (a negative parse), which made a hash NOT match
        // itself -- self-comparison must always be 0.
        expect(SimilarityService.hammingDistance(hash, hash), 0);
      });
    });

    group('clusterByTime', () {
      test('clusters photos within time window', () {
        final now = DateTime(2024, 1, 1, 12, 0, 0);
        final photos = [
          PhotoItem(
            id: '1',
            path: 'path1',
            createDateTime: now,
            fileSize: 1000,
          ),
          PhotoItem(
            id: '2',
            path: 'path2',
            createDateTime: now.add(const Duration(seconds: 30)),
            fileSize: 1000,
          ),
          PhotoItem(
            id: '3',
            path: 'path3',
            createDateTime: now.add(const Duration(seconds: 60)),
            fileSize: 1000,
          ),
          PhotoItem(
            id: '4',
            path: 'path4',
            createDateTime: now.add(const Duration(seconds: 150)), // 150s gap
            fileSize: 1000,
          ),
        ];

        final clusters = SimilarityService.clusterByTime(
          photos,
          timeWindowSeconds: 120,
        );

        expect(clusters.length, 2);
        expect(clusters[0].length, 3);
        expect(clusters[1].length, 1);
      });

      test('handles empty list', () {
        final clusters = SimilarityService.clusterByTime([]);
        expect(clusters.length, 0);
      });

      test('single photo creates one cluster', () {
        final photo = PhotoItem(
          id: '1',
          path: 'path1',
          createDateTime: DateTime.now(),
          fileSize: 1000,
        );

        final clusters = SimilarityService.clusterByTime([photo]);

        expect(clusters.length, 1);
        expect(clusters[0].length, 1);
      });

      test('respects custom time window', () {
        final now = DateTime(2024, 1, 1, 12, 0, 0);
        final photos = [
          PhotoItem(
            id: '1',
            path: 'path1',
            createDateTime: now,
            fileSize: 1000,
          ),
          PhotoItem(
            id: '2',
            path: 'path2',
            createDateTime: now.add(const Duration(seconds: 30)),
            fileSize: 1000,
          ),
        ];

        final clusters = SimilarityService.clusterByTime(
          photos,
          timeWindowSeconds: 20, // Tighter window
        );

        expect(clusters.length, 2);
      });
    });

    group('hammingDistance', () {
      test('calculates correct distance between hashes', () {
        final hash1 = 'abc123';
        final hash2 = 'abc124';

        final distance = SimilarityService.hammingDistance(hash1, hash2);

        // Bit-level, not hex-digit-level: '3' (0011) vs '4' (0100) differ
        // in 3 bits, not "1 differing character".
        expect(distance, 3);
      });

      test('returns 0 for identical hashes', () {
        final hash = 'abc123';
        final distance = SimilarityService.hammingDistance(hash, hash);

        expect(distance, 0);
      });

      test('returns high distance for completely different hashes', () {
        final hash1 = 'ffffff';
        final hash2 = '000000';

        final distance = SimilarityService.hammingDistance(hash1, hash2);

        // 6 hex digits = 24 bits, all differing.
        expect(distance, 24);
      });

      test('handles mismatched lengths', () {
        final hash1 = 'abc';
        final hash2 = 'abc123';

        final distance = SimilarityService.hammingDistance(hash1, hash2);

        expect(distance, 999);
      });

      test('handles empty hashes', () {
        final distance = SimilarityService.hammingDistance('', 'abc');

        expect(distance, 999);
      });

      test(
          'handles hashes with the top bit set (regression: int.parse '
          'throws on values above the signed 64-bit range, which a '
          '64-bit dHash hits roughly half the time)', () {
        final distance = SimilarityService.hammingDistance(
          '8000000000000000',
          '0000000000000000',
        );

        expect(distance, 1);
      });

      test(
          'two single-bit-different hex digits are NOT the same distance as '
          'two maximally-different hex digits (regression: a previous '
          'version compared hex characters, not bits, so \'0\' vs \'8\' '
          '(1 bit) and \'0\' vs \'f\' (4 bits) both counted as "1")', () {
        final oneBitOff = SimilarityService.hammingDistance(
            '0000000000000000', '8000000000000000');
        final fourBitsOff = SimilarityService.hammingDistance(
            '0000000000000000', 'f000000000000000');

        expect(oneBitOff, 1);
        expect(fourBitsOff, 4);
      });
    });

    group('groupBySimilarity', () {
      test('groups photos by perceptual hash similarity', () {
        final photos = [
          PhotoItem(
            id: '1',
            path: 'path1',
            createDateTime: DateTime.now(),
            fileSize: 1000,
          ),
          PhotoItem(
            id: '2',
            path: 'path2',
            createDateTime: DateTime.now(),
            fileSize: 1000,
          ),
          PhotoItem(
            id: '3',
            path: 'path3',
            createDateTime: DateTime.now(),
            fileSize: 1000,
          ),
        ];

        final hashes = {
          '1': 'abc123',
          '2': 'abc125', // Close to 1
          '3': 'fff000', // Far from 1 and 2
        };

        final groups = SimilarityService.groupBySimilarity(
          photos,
          hammingThreshold: 5,
          photoHashes: hashes,
        );

        expect(groups.length, 2);
        expect(groups[0].length, 2);
        expect(groups[1].length, 1);
      });

      test(
          'a photo with no hash still comes out as its own singleton group '
          '(regression: previously `continue`-d straight past groups.add, '
          'silently dropping it from the output entirely -- the result '
          'must be a partition of the input, every photo in exactly one '
          'group, not "every photo that happened to have a hash")', () {
        final photos = [
          PhotoItem(
            id: '1',
            path: 'path1',
            createDateTime: DateTime.now(),
            fileSize: 1000,
          ),
          PhotoItem(
            id: '2',
            path: 'path2',
            createDateTime: DateTime.now(),
            fileSize: 1000,
          ),
        ];

        final hashes = {'1': 'abc123'};

        final groups = SimilarityService.groupBySimilarity(
          photos,
          hammingThreshold: 5,
          photoHashes: hashes,
        );

        expect(groups.length, 2);
        expect(
          groups.map((g) => g.map((p) => p.id).toSet()),
          containsAll([
            {'1'},
            {'2'},
          ]),
        );
      });

      test('empty photo list returns empty groups', () {
        final groups = SimilarityService.groupBySimilarity(
          [],
          hammingThreshold: 5,
          photoHashes: {},
        );

        expect(groups.length, 0);
      });
    });
  });
}
