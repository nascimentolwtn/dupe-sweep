import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/screens/photo_slider_compare_screen.dart';

void main() {
  group('clampSliderPosition', () {
    test('passes through values already in range', () {
      expect(clampSliderPosition(0.0), 0.0);
      expect(clampSliderPosition(0.5), 0.5);
      expect(clampSliderPosition(1.0), 1.0);
    });

    test('clamps values below 0', () {
      expect(clampSliderPosition(-0.3), 0.0);
    });

    test('clamps values above 1', () {
      expect(clampSliderPosition(1.7), 1.0);
    });
  });
}
