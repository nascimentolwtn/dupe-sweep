import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/services/similarity_service.dart';
import 'package:dupesweep/models/photo_item.dart';

void main() {
  group('SimilarityService', () {
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

        expect(distance, 1);
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

        expect(distance, 6);
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

      test('handles photos with no hash', () {
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

        expect(groups.length, 1);
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
