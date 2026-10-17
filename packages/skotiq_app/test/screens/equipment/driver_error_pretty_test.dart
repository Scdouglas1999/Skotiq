// Verify the driver-error pretty-printer recognizes the
// common cross-driver patterns, and leaves
// everything else untouched.
//
// Pretty-print is layered on top of the raw message — the
// original text must always be reachable verbatim (here we assert it
// against `full`). Pretty-print must never silently hide content.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/utils/driver_error_pretty.dart';

void main() {
  group('PrettyError.format — null / empty handling', () {
    test('null source falls back to "(no message)" and is not recognized', () {
      final pretty = PrettyError.format(null);
      expect(pretty.full, '(no message)');
      expect(pretty.short, '(no message)');
      expect(pretty.recognized, isFalse);
    });

    test('empty / whitespace-only source falls back gracefully', () {
      final pretty = PrettyError.format('   ');
      expect(pretty.full, '(no message)');
      expect(pretty.recognized, isFalse);
    });
  });

  group('PrettyError.format — ASCOM HRESULT recognition', () {
    test('prepends the canonical name for a known ASCOM HRESULT', () {
      final pretty = PrettyError.format(
        'Slew refused: ASCOM error 0x80040403 - device offline',
      );
      expect(pretty.recognized, isTrue);
      // Canonical name comes from PrettyError.ascomHresultNames.
      expect(pretty.full.startsWith('ASCOM 0x80040403 NotConnectedException:'),
          isTrue);
      // Raw message must be preserved verbatim after the label.
      expect(pretty.full.contains('device offline'), isTrue);
    });

    test('lookup is case-insensitive on the hex literal', () {
      final pretty = PrettyError.format('Driver returned 0x80040401');
      expect(pretty.recognized, isTrue);
      expect(
        pretty.full,
        startsWith('ASCOM 0x80040401 InvalidValueException:'),
      );
    });

    test('uppercase hex literal still matches', () {
      final pretty = PrettyError.format('Hit 0x80040404 while parking');
      expect(pretty.recognized, isTrue);
      expect(
        pretty.full,
        startsWith('ASCOM 0x80040404 InvalidOperationException:'),
      );
    });

    test('common COM HRESULTs ASCOM drivers raise are mapped', () {
      // 0x80040154 - class not registered (driver not installed).
      final notRegistered = PrettyError.format('CoCreateInstance 0x80040154');
      expect(notRegistered.recognized, isTrue);
      expect(notRegistered.full, contains('class not registered'));

      // 0x800706BA - RPC server unavailable.
      final rpcDown = PrettyError.format('RPC failed (0x800706BA)');
      expect(rpcDown.recognized, isTrue);
      expect(rpcDown.full, contains('RPC server unavailable'));
    });

    test('unknown ASCOM HRESULT falls through unrecognized', () {
      // A code that is NOT in the conservative map must pass through
      // untouched: never invent a label that cannot be verified.
      final pretty = PrettyError.format('Driver raised 0xDEADBEEF');
      expect(pretty.recognized, isFalse);
      expect(pretty.full, 'Driver raised 0xDEADBEEF');
    });
  });

  group('PrettyError.format — Alpaca recognition', () {
    test('Alpaca HTTP 500 gets the canonical reason phrase', () {
      final pretty = PrettyError.format(
        'Alpaca returned HTTP 500: InvalidValue',
      );
      expect(pretty.recognized, isTrue);
      expect(pretty.full, startsWith('Alpaca HTTP 500 Internal Server Error:'));
    });

    test('Alpaca HTTP 400 is labelled Bad Request', () {
      final pretty = PrettyError.format('Alpaca call failed with HTTP 400');
      expect(pretty.recognized, isTrue);
      expect(pretty.full, startsWith('Alpaca HTTP 400 Bad Request:'));
    });

    test('Alpaca uses generic prefix when status code is unmapped', () {
      // 418 is not a real Alpaca code; we don't pretend to know what it
      // means, but we still mark it as Alpaca-recognized so the user
      // knows where it came from.
      final pretty = PrettyError.format('Alpaca returned HTTP 418');
      expect(pretty.recognized, isTrue);
      expect(pretty.full, startsWith('Alpaca HTTP 418:'));
    });

    test('stray HTTP-looking text without Alpaca/HTTP keywords is not claimed',
        () {
      final pretty = PrettyError.format('Sensor returned 500 lux');
      // No "alpaca" / "HTTP" / "status NNN" wording — must not falsely
      // claim this as an Alpaca error.
      expect(pretty.recognized, isFalse);
      expect(pretty.full, 'Sensor returned 500 lux');
    });
  });

  group('PrettyError.format — INDI recognition', () {
    test('INDI property + Alert state gets a structured label', () {
      final pretty = PrettyError.format(
        'INDI property CCD_EXPOSURE state Alert: hardware fault',
      );
      expect(pretty.recognized, isTrue);
      expect(pretty.full, startsWith('INDI CCD_EXPOSURE Alert:'));
      expect(pretty.full, contains('hardware fault'));
    });

    test('Generic INDI-prefixed messages without property still get a label',
        () {
      final pretty = PrettyError.format('INDI client lost server connection');
      expect(pretty.recognized, isTrue);
      expect(pretty.full, startsWith('INDI:'));
    });
  });

  group('PrettyError.format — unknown / vendor messages pass through', () {
    test('native vendor errors are not modified', () {
      // ZWO ASI / QHY / Touptek vendor messages are typically already
      // human-readable. We must not prepend anything.
      const raw =
          'ZWO ASI: ASI_ERROR_INVALID_INDEX - camera index out of range';
      final pretty = PrettyError.format(raw);
      expect(pretty.recognized, isFalse);
      expect(pretty.full, raw);
    });

    test('arbitrary free-form text passes through unchanged', () {
      const raw = 'Something went sideways on the bus';
      final pretty = PrettyError.format(raw);
      expect(pretty.recognized, isFalse);
      expect(pretty.full, raw);
    });
  });

  group('PrettyError.format — truncation', () {
    test('short field never exceeds maxShortChars', () {
      // Build a 200-char raw message.
      final raw = 'X' * 200;
      final pretty = PrettyError.format(raw);
      expect(pretty.short.length, lessThanOrEqualTo(PrettyError.maxShortChars));
      expect(pretty.full, raw); // full preserved
      expect(pretty.short, endsWith('…'));
    });

    test('messages shorter than the limit are not truncated', () {
      const raw = 'short message';
      final pretty = PrettyError.format(raw);
      expect(pretty.short, raw);
      expect(pretty.full, raw);
    });
  });
}
