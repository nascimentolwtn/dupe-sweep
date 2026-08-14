import 'package:flutter/foundation.dart';
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

      // `hash` is a plain (signed 64-bit) Dart int built via 64 left-shifts,
      // so whichever comparison lands in the top bit position can make it
      // negative -- and `int.toRadixString` on a negative value returns a
      // MINUS-SIGN-PREFIXED string of its magnitude (e.g. "-555555555555556"),
      // not a two's-complement unsigned hex string. That corrupted string
      // then parses back as a negative BigInt in hammingDistance, whose XOR
      // against a positive hash is negative, and `while (xor > BigInt.zero)`
      // exits immediately -- silently reporting distance 0 ("identical")
      // for unrelated photos, for roughly half of all possible hash values.
      // toUnsigned(64) reinterprets the same bit pattern as an unsigned
      // 64-bit value before formatting, which is what every consumer
      // (hammingDistance, the cache, the UI) actually expects.
      return BigInt.from(hash).toUnsigned(64).toRadixString(16).padLeft(
            16,
            '0',
          );
    } catch (e) {
      debugPrint('Error computing dHash: $e');
      return '';
    }
  }

  /// Calculate Hamming distance between two hashes, in bits.
  ///
  /// [hash1]/[hash2] are hex strings (see [computeDHash]); this parses them
  /// back to numbers and counts differing bits via XOR + popcount. A
  /// previous version compared the strings hex-digit-by-hex-digit instead,
  /// which is NOT the same thing: two digits that differ by a single bit
  /// ('0' vs '8') counted identically to two that differ by all four
  /// ('0' vs 'f'). That collapsed the real 0-64 bit range down to an
  /// effective 0-16 "digit" range, so [defaultHammingDistanceThreshold]
  /// (10, tuned for a 0-64 bit scale) was far looser than intended -- up to
  /// ~40 real bits could differ and still count as "similar", which is why
  /// visually unrelated photos were ending up in the same hash group.
  ///
  /// Uses [BigInt] rather than [int]: a 64-bit dHash with its top bit set
  /// (roughly half of all possible hash values) exceeds Dart's signed
  /// 64-bit `int` range and throws on `int.parse` -- `BigInt.parse` has no
  /// such limit, so every hash value parses and compares correctly.
  static int hammingDistance(String hash1, String hash2) {
    if (hash1.isEmpty || hash2.isEmpty || hash1.length != hash2.length) {
      return 999;
    }

    try {
      var xor = BigInt.parse(hash1, radix: 16) ^ BigInt.parse(hash2, radix: 16);
      var distance = 0;
      while (xor > BigInt.zero) {
        if (xor & BigInt.one == BigInt.one) distance++;
        xor >>= 1;
      }
      return distance;
    } on FormatException {
      return 999;
    }
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

      // A photo with no hash (a thumbnail fetch that failed, etc.) can't
      // be compared to anything, but it must still come out the other end
      // as its own singleton group -- `continue`-ing straight past
      // `groups.add(group)` below (the previous behavior) silently
      // dropped it from the output entirely, so the function's result
      // wasn't a partition of its input. Today that's masked by
      // buildPhotoGroups filtering singletons anyway, but a photo that
      // fails to hash would otherwise be unreviewable with zero feedback.
      if (photoHash.isNotEmpty) {
        for (final other in photos) {
          if (used.contains(other.id)) continue;

          final otherHash = photoHashes[other.id] ?? '';
          if (otherHash.isEmpty) continue;

          if (hammingDistance(photoHash, otherHash) <= hammingThreshold) {
            group.add(other);
            used.add(other.id);
          }
        }
      }

      groups.add(group);
    }

    return groups;
  }
}
