import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../models/photo_item.dart';

class SimilarityService {
  static const int defaultTimeWindowSeconds = 120;
  static const int defaultHammingDistanceThreshold = 10;

  /// Cluster photos by time window (in seconds).
  /// Returns list of groups, each containing photos taken within timeWindowSeconds of each other.
  static List<List<PhotoItem>> clusterByTime(
    List<PhotoItem> photos, {
    int timeWindowSeconds = defaultTimeWindowSeconds,
  }) {
    if (photos.isEmpty) return [];

    final clusters = <List<PhotoItem>>[];
    var currentCluster = <PhotoItem>[photos.first];

    for (int i = 1; i < photos.length; i++) {
      final timeDiff =
          photos[i].createDateTime.difference(photos[i - 1].createDateTime);

      if (timeDiff.inSeconds <= timeWindowSeconds) {
        currentCluster.add(photos[i]);
      } else {
        clusters.add(currentCluster);
        currentCluster = [photos[i]];
      }
    }
    clusters.add(currentCluster);

    return clusters;
  }

  /// Compute dHash (difference hash) from image bytes.
  /// Returns a 64-bit hash as a string.
  static String computeDHash(Uint8List imageBytes) {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return '';

      // Resize to 9x8 and convert to grayscale
      final resized = img.copyResize(image, width: 9, height: 8);
      final gray = img.grayscale(resized);

      // Compute difference hash
      var hash = 0;
      for (int y = 0; y < gray.height; y++) {
        for (int x = 0; x < gray.width - 1; x++) {
          final pixel1 = gray.getPixelSafe(x, y);
          final pixel2 = gray.getPixelSafe(x + 1, y);

          final lum1 = pixel1.r.toInt();
          final lum2 = pixel2.r.toInt();

          hash = (hash << 1) | (lum1 > lum2 ? 1 : 0);
        }
      }

      return hash.toRadixString(16).padLeft(16, '0');
    } catch (e) {
      print('Error computing dHash: $e');
      return '';
    }
  }

  /// Calculate Hamming distance between two hashes.
  static int hammingDistance(String hash1, String hash2) {
    if (hash1.isEmpty || hash2.isEmpty || hash1.length != hash2.length) {
      return 999;
    }

    int distance = 0;
    for (int i = 0; i < hash1.length; i++) {
      if (hash1[i] != hash2[i]) distance++;
    }
    return distance;
  }

  /// Group photos by perceptual similarity using dHash.
  static List<List<PhotoItem>> groupBySimilarity(
    List<PhotoItem> photos, {
    int hammingThreshold = defaultHammingDistanceThreshold,
    required Map<String, String> photoHashes,
  }) {
    final groups = <List<PhotoItem>>[];
    final used = <String>{};

    for (final photo in photos) {
      if (used.contains(photo.id)) continue;

      final group = <PhotoItem>[photo];
      used.add(photo.id);
      final photoHash = photoHashes[photo.id] ?? '';

      if (photoHash.isEmpty) continue;

      for (final other in photos) {
        if (used.contains(other.id)) continue;

        final otherHash = photoHashes[other.id] ?? '';
        if (otherHash.isEmpty) continue;

        if (hammingDistance(photoHash, otherHash) <= hammingThreshold) {
          group.add(other);
          used.add(other.id);
        }
      }

      groups.add(group);
    }

    return groups;
  }

}
