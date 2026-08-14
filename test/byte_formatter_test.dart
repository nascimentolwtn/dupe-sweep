import 'package:flutter_test/flutter_test.dart';
import 'package:dupesweep/utils/byte_formatter.dart';

void main() {
  group('ByteFormatter.format', () {
    test('formats 0 bytes as bytes', () {
      expect(ByteFormatter.format(0), '0 B');
    });

    test('formats sub-KB values as bytes', () {
      expect(ByteFormatter.format(500), '500 B');
    });

    test('formats 1023 bytes as bytes (just under the KB boundary)', () {
      expect(ByteFormatter.format(1023), '1023 B');
    });

    test('formats exactly 1024 bytes as KB', () {
      expect(ByteFormatter.format(1024), '1.0 KB');
    });

    test('formats a mid-range KB value with one decimal place', () {
      expect(ByteFormatter.format(1536), '1.5 KB');
    });

    test('formats just under the MB boundary as KB', () {
      expect(ByteFormatter.format(1024 * 1024 - 1), '1024.0 KB');
    });

    test('formats exactly 1 MB as MB', () {
      expect(ByteFormatter.format(1024 * 1024), '1.0 MB');
    });

    test('formats a mid-range MB value with one decimal place', () {
      expect(ByteFormatter.format((1024 * 1024 * 2.5).round()), '2.5 MB');
    });

    test('formats just under the GB boundary as MB', () {
      expect(ByteFormatter.format(1024 * 1024 * 1024 - 1), '1024.0 MB');
    });

    test('formats exactly 1 GB as GB', () {
      expect(ByteFormatter.format(1024 * 1024 * 1024), '1.0 GB');
    });

    test('formats a very large value as GB', () {
      expect(ByteFormatter.format(1024 * 1024 * 1024 * 10), '10.0 GB');
    });

    test(
        'negative values fall through to the "bytes" branch as-is '
        '(documents current behavior -- ByteFormatter has no negative-input '
        'guard, and fileSize should never be negative in practice)', () {
      expect(ByteFormatter.format(-5), '-5 B');
    });
  });
}
