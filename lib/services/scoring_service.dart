import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../models/photo_item.dart';

class ScoringService {
  /// Compute sharpness score using Laplacian variance on a thumbnail.
  /// Returns a score between 0 and 1, where 1 is sharpest.
  ///
  /// Computed as the MAX variance across a grid of tiles, not one variance
  /// over the whole frame. A single whole-image variance gets diluted by
  /// any large flat region (sky, wall, blown highlights, smooth skin) even
  /// when the actual subject is in sharp focus elsewhere in the same
  /// photo -- that flat-vs-focus confound was landing genuinely sharp
  /// photos in the same near-zero range as truly blurry ones. Taking the
  /// sharpest tile fixes that asymmetrically: a photo blurry everywhere
  /// still scores low (no tile has real edge content), while a sharp
  /// subject against a flat background is no longer dragged down by the
  /// background.
  static double computeSharpness(Uint8List imageBytes) {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return 0.0;

      // Downscale to 200x200 and convert to grayscale for speed
      final resized = img.copyResize(image, width: 200, height: 200);
      final gray = img.grayscale(resized);

      const tilesPerSide = 5;
      final tileW = gray.width ~/ tilesPerSide;
      final tileH = gray.height ~/ tilesPerSide;
      double maxVariance = 0.0;

      for (int ty = 0; ty < tilesPerSide; ty++) {
        for (int tx = 0; tx < tilesPerSide; tx++) {
          // Stay 1px inside the tile (and the image) on every edge so the
          // Laplacian's 4-neighbor sample never reads outside gray's
          // bounds.
          final x0 = (tx * tileW).clamp(1, gray.width - 2);
          final y0 = (ty * tileH).clamp(1, gray.height - 2);
          final x1 = (tx == tilesPerSide - 1)
              ? gray.width - 1
              : ((tx + 1) * tileW).clamp(1, gray.width - 1);
          final y1 = (ty == tilesPerSide - 1)
              ? gray.height - 1
              : ((ty + 1) * tileH).clamp(1, gray.height - 1);

          double sumLaplacian = 0.0;
          double sumSquared = 0.0;
          int pixelCount = 0;

          for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
              final center = _getGrayValue(gray.getPixelSafe(x, y));
              final north = _getGrayValue(gray.getPixelSafe(x, y - 1));
              final south = _getGrayValue(gray.getPixelSafe(x, y + 1));
              final east = _getGrayValue(gray.getPixelSafe(x + 1, y));
              final west = _getGrayValue(gray.getPixelSafe(x - 1, y));

              // Laplacian operator
              final laplacian = 4 * center - north - south - east - west;
              sumLaplacian += laplacian;
              sumSquared += laplacian * laplacian;
              pixelCount++;
            }
          }

          if (pixelCount == 0) continue;

          final mean = sumLaplacian / pixelCount;
          final variance = (sumSquared / pixelCount) - (mean * mean);
          if (variance > maxVariance) maxVariance = variance;
        }
      }

      // Normalize variance to 0-1 range
      final normalizedVariance = maxVariance / 100000.0;
      return (normalizedVariance > 1.0) ? 1.0 : normalizedVariance;
    } catch (e) {
      debugPrint('Error computing sharpness: $e');
      return 0.0;
    }
  }

  /// Compute exposure score based on histogram.
  /// Returns a score between 0 and 1, where 1 means well-exposed.
  /// Penalizes very dark or blown-out images.
  static double computeExposure(Uint8List imageBytes) {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return 0.0;

      // Downscale for speed
      final resized = img.copyResize(image, width: 100, height: 100);
      final gray = img.grayscale(resized);

      final histogram = List<int>.filled(256, 0);

      for (int y = 0; y < gray.height; y++) {
        for (int x = 0; x < gray.width; x++) {
          final value = _getGrayValue(gray.getPixelSafe(x, y));
          histogram[value]++;
        }
      }

      // Count pixels in dark and bright regions
      int darkPixels = 0;
      int brightPixels = 0;

      for (int i = 0; i < 50; i++) {
        darkPixels += histogram[i];
      }
      for (int i = 200; i < 256; i++) {
        brightPixels += histogram[i];
      }

      final totalPixels = gray.width * gray.height;
      final darkRatio = darkPixels / totalPixels;
      final brightRatio = brightPixels / totalPixels;

      // Penalize if more than 30% is very dark or very bright
      double exposureScore = 1.0;
      if (darkRatio > 0.3) exposureScore -= darkRatio * 0.5;
      if (brightRatio > 0.3) exposureScore -= brightRatio * 0.5;

      return exposureScore.clamp(0.0, 1.0);
    } catch (e) {
      debugPrint('Error computing exposure: $e');
      return 0.5;
    }
  }

  /// Rank photos in a group by overall quality.
  static List<PhotoItem> rankByQuality(List<PhotoItem> photos) {
    final ranked = List<PhotoItem>.from(photos);
    ranked.sort((a, b) {
      final scoreA = a.overallScore;
      final scoreB = b.overallScore;
      return scoreB.compareTo(scoreA); // Descending
    });
    return ranked;
  }

  // Takes the image package's Pixel type (what getPixelSafe actually
  // returns as of image v4 -- this project's dependency version, not the
  // v3 this file was originally written against) rather than a raw int,
  // and reads channel values via the .r/.g/.b properties instead of the
  // removed getRed/getGreen/getBlue free functions.
  static int _getGrayValue(img.Pixel pixel) {
    final r = pixel.r.toInt();
    final g = pixel.g.toInt();
    final b = pixel.b.toInt();
    // r/g/b are already 0-255 (the image was already converted to
    // grayscale before this is called), so the weighted sum is already in
    // 0-255 range -- multiplying by 255 again (the original code) would
    // overflow histogram[value] far past its 256-slot bounds and throw
    // RangeError on the very first non-black pixel.
    return (0.299 * r + 0.587 * g + 0.114 * b).toInt();
  }
}
