import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('CoordinateParser', () {
    test('rejects impossible sexagesimal components and pole overflow', () {
      expect(CoordinateParser.parseRa('12:60:00'), isNull);
      expect(CoordinateParser.parseRa('23:59:60'), isNull);
      expect(CoordinateParser.parseRa('24:00:00'), isNull);
      expect(CoordinateParser.parseDec('+45:60:00'), isNull);
      expect(CoordinateParser.parseDec('+90:00:01'), isNull);
      expect(CoordinateParser.parseDec('-90:30:00'), isNull);
    });

    test('accepts letter formats case-insensitively and preserves -0 DMS', () {
      expect(CoordinateParser.parseRa('05H 30M 00S'), 5.5);
      expect(CoordinateParser.parseDec('+45D 30M 00S'), 45.5);
      expect(CoordinateParser.parseDec('-00D 30M 00S'), -0.5);
    });

    test('framing uses the same strict parser contract', () {
      expect(CoordinateUtils.parseRA('12:60:00'), isNull);
      expect(CoordinateUtils.parseDec('+90:00:01'), isNull);
      expect(CoordinateUtils.parseRA('05H 30M 00S'), 5.5);
      expect(CoordinateUtils.parseDec('-00D 30M 00S'), -0.5);
    });
  });

  group('CoordinateParser.formatRaHms / formatDecDms', () {
    // These two formatters rounded each sexagesimal field independently, so a
    // value whose minutes land just under a whole minute rendered an impossible
    // time: formatRaHms(5.6) produced '05:35:60.00'. The parser above already
    // rejects '23:59:60', so the app was printing coordinates it would itself
    // refuse to read back — and the mosaic project header was printing them as
    // the authoritative target region.
    test('carries a rounded 60 instead of printing it', () {
      expect(CoordinateParser.formatRaHms(5.6), '05:36:00.00');
      expect(CoordinateParser.formatDecDms(5.6), '+05:36:00.00');
      expect(CoordinateParser.formatDecDms(-5.6), '-05:36:00.00');
    });

    test('every formatted value round-trips through the strict parser', () {
      for (var i = 0; i < 2400; i++) {
        final ra = i * 0.01;
        final formatted = CoordinateParser.formatRaHms(ra);
        expect(
          CoordinateParser.parseRa(formatted),
          isNotNull,
          reason: 'formatRaHms($ra) = "$formatted" is not parseable',
        );
      }
      for (var i = -8900; i <= 8900; i += 7) {
        final dec = i * 0.01;
        final formatted = CoordinateParser.formatDecDms(dec);
        expect(
          CoordinateParser.parseDec(formatted),
          isNotNull,
          reason: 'formatDecDms($dec) = "$formatted" is not parseable',
        );
      }
    });

    test('exact values still format exactly', () {
      expect(CoordinateParser.formatRaHms(0.0), '00:00:00.00');
      expect(CoordinateParser.formatRaHms(5.5), '05:30:00.00');
      expect(CoordinateParser.formatDecDms(45.5), '+45:30:00.00');
      expect(CoordinateParser.formatDecDms(-0.5), '-00:30:00.00');
      expect(CoordinateParser.formatDecDms(90.0), '+90:00:00.00');
    });

    test('folds an out-of-range RA into a real time of day', () {
      // 24h is not a time; neither is a negative hour.
      expect(CoordinateParser.formatRaHms(24.0), '00:00:00.00');
      expect(CoordinateParser.formatRaHms(25.5), '01:30:00.00');
      expect(CoordinateParser.formatRaHms(-0.5), '23:30:00.00');
    });

    test('says so rather than printing a bogus number for a non-finite '
        'coordinate', () {
      expect(CoordinateParser.formatRaHms(double.nan), '--:--:--.--');
      expect(CoordinateParser.formatDecDms(double.infinity), '+--:--:--.--');
    });
  });

  group('CoordinateFormat.ra', () {
    test('paddedLetters + oneDecimal (default) matches legacy output', () {
      // 12h 20m 42.0s for 12.345 hours.
      expect(CoordinateFormat.ra(12.345), '12h 20m 42.0s');
    });

    test('zero-pads hours and minutes (seconds use one decimal, unpadded)', () {
      // 5.5 h -> 05h 30m 0.0s. The seconds component is rendered with
      // toStringAsFixed(1) and intentionally NOT zero-padded, matching the
      // legacy private formatters this consolidates.
      expect(CoordinateFormat.ra(5.5), '05h 30m 0.0s');
    });

    test('paddedLetters + integerRounded', () {
      expect(
        CoordinateFormat.ra(12.345, seconds: SecondsPrecision.integerRounded),
        '12h 20m 42s',
      );
    });

    test('paddedLetters + integerFloored', () {
      // 42.0s exactly floors to 42.
      expect(
        CoordinateFormat.ra(12.345, seconds: SecondsPrecision.integerFloored),
        '12h 20m 42s',
      );
    });

    test('paddedColons + integerRounded', () {
      expect(
        CoordinateFormat.ra(
          12.345,
          style: SexagesimalStyle.paddedColons,
          seconds: SecondsPrecision.integerRounded,
        ),
        '12:20:42',
      );
    });
  });

  group('CoordinateFormat carries the seconds field', () {
    // CoordinateFormat used to format each sexagesimal field independently, so
    // an angle whose seconds round up to a whole minute printed a value that
    // does not exist — and that this package's own parser rejects. The carry
    // has to be structural (quantize the whole angle, then decompose), not a
    // special case, or the next precision added re-opens it.
    test('never prints 60 seconds', () {
      expect(CoordinateFormat.ra(5.6), '05h 36m 0.0s');
      expect(
        CoordinateFormat.ra(5.99999, seconds: SecondsPrecision.integerRounded),
        '06h 00m 00s',
      );
      expect(CoordinateFormat.dec(-5.6), "-05° 36' 0.0\"");
      expect(
        CoordinateFormat.dec(5.99999, seconds: SecondsPrecision.integerRounded),
        "+06° 00' 00\"",
      );
    });

    test('every formatted RA/Dec reads back through the strict parser', () {
      for (var i = 0; i < 2400; i++) {
        final ra = i * 0.01;
        for (final precision in SecondsPrecision.values) {
          final formatted = CoordinateFormat.ra(
            ra,
            style: SexagesimalStyle.paddedColons,
            seconds: precision,
          );
          expect(
            CoordinateParser.parseRa(formatted),
            isNotNull,
            reason: 'CoordinateFormat.ra($ra, $precision) = "$formatted"',
          );
        }
      }
      for (var i = -8900; i <= 8900; i += 7) {
        final dec = i * 0.01;
        for (final precision in SecondsPrecision.values) {
          final formatted = CoordinateFormat.dec(
            dec,
            style: SexagesimalStyle.paddedColons,
            seconds: precision,
          );
          expect(
            CoordinateParser.parseDec(formatted),
            isNotNull,
            reason: 'CoordinateFormat.dec($dec, $precision) = "$formatted"',
          );
        }
      }
    });

    test(
      'twoDecimal is the zero-padded shape CoordinateParser delegates to',
      () {
        expect(
          CoordinateFormat.ra(
            5.5,
            style: SexagesimalStyle.paddedColons,
            seconds: SecondsPrecision.twoDecimal,
          ),
          '05:30:00.00',
        );
        expect(
          CoordinateFormat.dec(
            -0.5,
            style: SexagesimalStyle.paddedColons,
            seconds: SecondsPrecision.twoDecimal,
          ),
          '-00:30:00.00',
        );
      },
    );
  });

  group('CoordinateFormat.dec', () {
    test('positive value gets explicit + sign (default oneDecimal)', () {
      // Seconds use toStringAsFixed(1), unpadded, matching legacy formatters.
      expect(CoordinateFormat.dec(45.5), "+45° 30' 0.0\"");
    });

    test('negative value gets - sign; degrees/minutes zero-padded', () {
      expect(CoordinateFormat.dec(-5.25), "-05° 15' 0.0\"");
    });

    test('paddedLetters + integerRounded', () {
      expect(
        CoordinateFormat.dec(-45.5, seconds: SecondsPrecision.integerRounded),
        "-45° 30' 00\"",
      );
    });

    test('paddedColons + integerRounded', () {
      expect(
        CoordinateFormat.dec(
          45.5,
          style: SexagesimalStyle.paddedColons,
          seconds: SecondsPrecision.integerRounded,
        ),
        '+45:30:00',
      );
    });
  });
}
