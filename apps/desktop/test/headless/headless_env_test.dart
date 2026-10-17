// Tests for the env-parsing helpers in
// apps/desktop/lib/headless/headless_env.dart.
//
// `envFlag` reads Platform.environment directly, so it cannot be driven from a
// pure unit test (Dart cannot mutate the process environment after launch).
// These tests cover the deterministic surface: `trimToNull` (pure on its input)
// and `envFlag` against absent variables (the only env state we can guarantee).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless/headless_env.dart';

void main() {
  group('trimToNull', () {
    test('returns null for null input', () {
      expect(trimToNull(null), isNull);
    });

    test('returns null for an empty string', () {
      expect(trimToNull(''), isNull);
    });

    test('returns null for whitespace-only input', () {
      expect(trimToNull('   '), isNull);
      expect(trimToNull('\t \n'), isNull);
    });

    test('trims surrounding whitespace from a real value', () {
      expect(trimToNull('  hello  '), 'hello');
      expect(trimToNull('\ttoken\n'), 'token');
    });

    test('preserves an already-trimmed value verbatim', () {
      expect(trimToNull('value'), 'value');
    });

    test('keeps interior whitespace intact', () {
      expect(trimToNull('  a b  '), 'a b');
    });
  });

  group('envFlag', () {
    test('returns false for an unset environment variable', () {
      // Generated name that cannot collide with a real process env var.
      expect(envFlag('SKOTIQ_TEST_UNSET_FLAG_DO_NOT_SET_XYZ'), isFalse);
    });
  });
}
