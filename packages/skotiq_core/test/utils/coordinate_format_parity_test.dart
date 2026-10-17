import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Parity pins for the private `_formatRa` / `_formatDec` helpers folded into
/// [CoordinateFormat].
///
/// Every group below names the call site it covers and pins the byte-for-byte
/// string that site prints. These strings are user-visible contract: a style
/// whose output changes has silently changed what a screen shows.
///
/// Two families of input are deliberately NOT preserved, because the retired
/// helpers were wrong there and the canonical decomposition (quantize the whole
/// angle once, then split) cannot reproduce the error:
///
///  1. **The impossible-60 carry.** Every field-by-field helper printed
///     `05h 35m 60.0s` for 5.6h — a time `CoordinateParser` itself rejects.
///  2. **Double-truncation loss.** Helpers that floored the seconds field after
///     two float subtractions lost a whole second/arcsecond on ~7% of inputs
///     (`0.015h` is exactly 54s but printed `53s`).
///
/// Both are pinned explicitly at the bottom so a future change that reverts to
/// field-by-field decomposition fails here.
void main() {
  group('run_dashboard_format.formatRA / formatDec (paddedLetters, rounded, '
      'wrapping)', () {
    String ra(double v) => CoordinateFormat.ra(
      v,
      seconds: SecondsPrecision.integerRounded,
      wrapHours: true,
    );
    String dec(double v) =>
        CoordinateFormat.dec(v, seconds: SecondsPrecision.integerRounded);

    test('reproduces the retired dashboard formatter exactly', () {
      expect(ra(0.0), '00h 00m 00s');
      expect(ra(5.5), '05h 30m 00s');
      expect(ra(12.345), '12h 20m 42s');
      expect(ra(23.5), '23h 30m 00s');
      expect(ra(5.6), '05h 36m 00s');
      expect(dec(0.0), "+00° 00' 00\"");
      expect(dec(45.5), "+45° 30' 00\"");
      expect(dec(-5.25), "-05° 15' 00\"");
      expect(dec(-89.9), "-89° 54' 00\"");
      expect(dec(89.99), "+89° 59' 24\"");
    });

    test('folds a negative or >24h RA into a real time of day', () {
      expect(ra(-0.5), '23h 30m 00s');
      expect(ra(25.5), '01h 30m 00s');
      expect(ra(24.0), '00h 00m 00s');
    });
  });

  group('target_header_card / _motion_rich (paddedLetters, rounded)', () {
    test('formatDecDegAsDms and _formatRA/_formatDec shapes', () {
      expect(
        CoordinateFormat.ra(12.345, seconds: SecondsPrecision.integerRounded),
        '12h 20m 42s',
      );
      expect(
        CoordinateFormat.ra(23.5, seconds: SecondsPrecision.integerRounded),
        '23h 30m 00s',
      );
      expect(
        CoordinateFormat.dec(-89.9, seconds: SecondsPrecision.integerRounded),
        "-89° 54' 00\"",
      );
      expect(
        CoordinateFormat.dec(-0.5, seconds: SecondsPrecision.integerRounded),
        "-00° 30' 00\"",
      );
    });

    test('formatRaHoursAsHms wrapped, seconds zero-padded to SS.s', () {
      String f(double v) => CoordinateFormat.ra(
        v,
        seconds: SecondsPrecision.oneDecimalPadded,
        wrapHours: true,
      );
      expect(f(0.0), '00h 00m 00.0s');
      expect(f(5.5), '05h 30m 00.0s');
      expect(f(12.345), '12h 20m 42.0s');
      expect(f(-0.5), '23h 30m 00.0s');
      expect(f(25.5), '01h 30m 00.0s');
    });
  });

  group('centering_dialog / details_panel / object_info_tooltip '
      '(paddedLetters, oneDecimalPadded)', () {
    String ra(double v) =>
        CoordinateFormat.ra(v, seconds: SecondsPrecision.oneDecimalPadded);
    String dec(double v) =>
        CoordinateFormat.dec(v, seconds: SecondsPrecision.oneDecimalPadded);

    test('zero-pads the seconds field to a fixed SS.s width', () {
      expect(ra(0.0), '00h 00m 00.0s');
      expect(ra(5.5), '05h 30m 00.0s');
      expect(ra(12.345), '12h 20m 42.0s');
      expect(ra(23.5), '23h 30m 00.0s');
      expect(dec(0.0), "+00° 00' 00.0\"");
      expect(dec(45.5), "+45° 30' 00.0\"");
      expect(dec(-5.25), "-05° 15' 00.0\"");
      expect(dec(89.99), "+89° 59' 24.0\"");
    });

    test('object_info_tooltip is handed DEGREES and normalizes them', () {
      String f(double deg) => CoordinateFormat.raFromDegrees(
        deg,
        seconds: SecondsPrecision.oneDecimalPadded,
      );
      expect(f(0.0), '00h 00m 00.0s');
      expect(f(82.5), '05h 30m 00.0s');
      expect(f(185.175), '12h 20m 42.0s');
      // The retired helper wrapped the HOURS field but not the minutes, so an
      // out-of-range degree printed '23h -1440m 00.0s' / '01h 1440m 00.0s'.
      expect(f(-15.0), '23h 00m 00.0s');
      expect(f(375.0), '01h 00m 00.0s');
    });
  });

  group('framing CoordinateUtils / _measurement_panel (paddedLetters, '
      'oneDecimal, seconds NOT padded)', () {
    test('seconds render with toStringAsFixed(1) and no zero padding', () {
      expect(CoordinateFormat.ra(0.0), '00h 00m 0.0s');
      expect(CoordinateFormat.ra(5.5), '05h 30m 0.0s');
      expect(CoordinateFormat.ra(12.345), '12h 20m 42.0s');
      expect(CoordinateFormat.dec(45.5), "+45° 30' 0.0\"");
      expect(CoordinateFormat.dec(-89.9), "-89° 54' 0.0\"");
    });

    test('_measurement_panel hands over DEGREES via an explicit /15', () {
      expect(CoordinateFormat.ra(82.5 / 15.0), '05h 30m 0.0s');
      expect(CoordinateFormat.ra(352.5 / 15.0), '23h 30m 0.0s');
    });
  });

  group('mount_tab / mount_control_card / celestial_grid (compactLetters)', () {
    test('no separators, every field zero-padded', () {
      expect(
        CoordinateFormat.ra(
          12.345,
          style: SexagesimalStyle.compactLetters,
          seconds: SecondsPrecision.integerRounded,
        ),
        '12h20m42s',
      );
      expect(
        CoordinateFormat.ra(
          5.5,
          style: SexagesimalStyle.compactLetters,
          seconds: SecondsPrecision.integerRounded,
        ),
        '05h30m00s',
      );
      expect(
        CoordinateFormat.dec(
          -89.9,
          style: SexagesimalStyle.compactLetters,
          seconds: SecondsPrecision.integerRounded,
        ),
        "-89°54'00\"",
      );
      expect(
        CoordinateFormat.decDm(
          -5.25,
          style: SexagesimalStyle.compactLetters,
          minutes: MinutesPrecision.rounded,
        ),
        "-05°15'",
      );
      expect(
        CoordinateFormat.decDm(
          89.99,
          style: SexagesimalStyle.compactLetters,
          minutes: MinutesPrecision.rounded,
        ),
        "+89°59'",
      );
    });

    test('celestial_grid / first_light_detectors take DEGREES', () {
      expect(
        CoordinateFormat.raHmFromDegrees(
          185.175,
          style: SexagesimalStyle.compactLetters,
          minutes: MinutesPrecision.rounded,
        ),
        '12h21m',
      );
      expect(
        CoordinateFormat.raHmFromDegrees(
          185.175,
          style: SexagesimalStyle.compactLetters,
        ),
        '12h20m',
      );
      expect(
        CoordinateFormat.raHmFromDegrees(
          -15.0,
          style: SexagesimalStyle.compactLetters,
        ),
        '23h00m',
      );
      expect(
        CoordinateFormat.raHmFromDegrees(
          375.0,
          style: SexagesimalStyle.compactLetters,
        ),
        '01h00m',
      );
      expect(
        CoordinateFormat.decDm(-89.9, style: SexagesimalStyle.compactLetters),
        "-89°54'",
      );
    });
  });

  group('quick_start / finder_chart / target_preview / CoordinateFormatUtils '
      '(plainLetters — nothing zero-padded)', () {
    test('oneDecimal seconds', () {
      String f(double v) =>
          CoordinateFormat.ra(v, style: SexagesimalStyle.plainLetters);
      expect(f(0.0), '0h 0m 0.0s');
      expect(f(5.5), '5h 30m 0.0s');
      expect(f(12.345), '12h 20m 42.0s');
      expect(f(23.5), '23h 30m 0.0s');
    });

    test('integerFloored seconds are unpadded under plainLetters', () {
      String ra(double v) => CoordinateFormat.ra(
        v,
        style: SexagesimalStyle.plainLetters,
        seconds: SecondsPrecision.integerFloored,
      );
      String dec(double v) => CoordinateFormat.dec(
        v,
        style: SexagesimalStyle.plainLetters,
        seconds: SecondsPrecision.integerFloored,
      );
      expect(ra(0.0), '0h 0m 0s');
      expect(ra(12.345), '12h 20m 42s');
      expect(ra(23.5), '23h 30m 0s');
      expect(dec(0.0), "+0° 0' 0\"");
      expect(dec(45.5), "+45° 30' 0\"");
      expect(dec(-5.25), "-5° 15' 0\"");
      expect(dec(-89.9), "-89° 54' 0\"");
    });

    test('CoordinateFormatUtils wraps into [0, 24)', () {
      expect(
        CoordinateFormat.ra(
          -0.5,
          style: SexagesimalStyle.plainLetters,
          wrapHours: true,
        ),
        '23h 30m 0.0s',
      );
      expect(
        CoordinateFormat.raHm(
          25.5,
          style: SexagesimalStyle.plainLetters,
          wrapHours: true,
        ),
        '1h 30m',
      );
      expect(
        CoordinateFormat.decDm(-89.9, style: SexagesimalStyle.plainLetters),
        "-89° 54'",
      );
    });

    test('devices_tab / mount_controls / _save_template hours+minutes', () {
      String f(double v) =>
          CoordinateFormat.raHm(v, style: SexagesimalStyle.plainLetters);
      expect(f(0.0), '0h 0m');
      expect(f(5.5), '5h 30m');
      expect(f(12.345), '12h 20m');
      expect(f(23.5), '23h 30m');
    });
  });

  group('sky_atlas_format / first_light_flow_dialog (leadPlainLetters)', () {
    test('leading field unpadded, minutes zero-padded', () {
      String ra(double deg) => CoordinateFormat.raHmFromDegrees(
        deg,
        style: SexagesimalStyle.leadPlainLetters,
        minutes: MinutesPrecision.rounded,
      );
      String dec(double deg) => CoordinateFormat.decDm(
        deg,
        style: SexagesimalStyle.leadPlainLetters,
        minutes: MinutesPrecision.rounded,
      );
      expect(ra(0.0), '0h 00m');
      expect(ra(15.0), '1h 00m');
      expect(ra(180.0), '12h 00m');
      expect(ra(185.175), '12h 21m');
      expect(ra(-15.0), '23h 00m');
      expect(ra(375.0), '1h 00m');
      expect(dec(0.0), "+0° 00'");
      expect(dec(45.5), "+45° 30'");
      expect(dec(-30.25), "-30° 15'");
      expect(dec(-89.9), "-89° 54'");
    });

    test('a rounded 60th minute carries into the hour/degree', () {
      // The retired helpers special-cased `if (m == 60)`; the canonical
      // quantizes at the minute so the case cannot arise.
      expect(
        CoordinateFormat.raHmFromDegrees(
          14.99,
          style: SexagesimalStyle.leadPlainLetters,
          minutes: MinutesPrecision.rounded,
        ),
        '1h 00m',
      );
      expect(
        CoordinateFormat.decDm(
          44.9999,
          style: SexagesimalStyle.leadPlainLetters,
          minutes: MinutesPrecision.rounded,
        ),
        "+45° 00'",
      );
    });
  });

  group('transient_alerts_panel (compactLeadPlainLetters)', () {
    test('unpadded lead, padded rest, no separators', () {
      String ra(double v) => CoordinateFormat.ra(
        v,
        style: SexagesimalStyle.compactLeadPlainLetters,
        seconds: SecondsPrecision.integerFloored,
      );
      String dec(double v) => CoordinateFormat.decDm(
        v,
        style: SexagesimalStyle.compactLeadPlainLetters,
      );
      expect(ra(0.0), '0h00m00s');
      expect(ra(5.5), '5h30m00s');
      expect(ra(12.345), '12h20m42s');
      expect(ra(23.5), '23h30m00s');
      expect(dec(0.0), "+0°00'");
      expect(dec(45.5), "+45°30'");
      expect(dec(-5.25), "-5°15'");
      expect(dec(-89.9), "-89°54'");
    });
  });

  group(
    'mpc_export_panel._formatRaBrief (compactLetters, oneDecimalPadded)',
    () {
      test('degrees in, HHhMMmSS.Ss out', () {
        String f(double deg) => CoordinateFormat.raFromDegrees(
          deg,
          style: SexagesimalStyle.compactLetters,
          seconds: SecondsPrecision.oneDecimalPadded,
        );
        expect(f(0.0), '00h00m00.0s');
        expect(f(82.5), '05h30m00.0s');
        expect(f(185.175), '12h20m42.0s');
        expect(f(352.5), '23h30m00.0s');
      });
    },
  );

  group(
    'decDecimal (devices_tab / mount_controls / _save_template_dialog)',
    () {
      test('explicit + on non-negative, minus comes from the number', () {
        expect(CoordinateFormat.decDecimal(0.0), '+0.0°');
        expect(CoordinateFormat.decDecimal(45.5), '+45.5°');
        expect(CoordinateFormat.decDecimal(-5.25), '-5.3°');
        expect(CoordinateFormat.decDecimal(-89.9), '-89.9°');
        expect(CoordinateFormat.decDecimal(-0.5), '-0.5°');
      });
    },
  );

  group('deliberate corrections the retired copies could not make', () {
    test(
      'the impossible 60th second/arcminute carries instead of printing',
      () {
        // Legacy field-by-field output for 5.6h / 5.6° is listed beside each.
        expect(CoordinateFormat.ra(5.6), '05h 36m 0.0s'); // was 05h 35m 60.0s
        expect(
          CoordinateFormat.ra(
            5.6,
            style: SexagesimalStyle.compactLetters,
            seconds: SecondsPrecision.integerRounded,
          ),
          '05h36m00s',
        ); // was 05h35m60s
        expect(
          CoordinateFormat.dec(5.6, seconds: SecondsPrecision.integerRounded),
          "+05° 36' 00\"",
        ); // was +05° 35' 60"
        expect(
          CoordinateFormat.raHmFromDegrees(
            84.0,
            style: SexagesimalStyle.compactLetters,
          ),
          '05h36m',
        ); // was 05h35m
      },
    );

    test('a whole second is no longer lost to double truncation', () {
      // 0.015h is exactly 54s; the retired floored helpers printed 53s.
      expect(
        CoordinateFormat.ra(
          0.015,
          style: SexagesimalStyle.plainLetters,
          seconds: SecondsPrecision.integerFloored,
        ),
        '0h 0m 54s',
      );
      // 89.99° is exactly 89°59'24"; the retired helpers printed 23".
      expect(
        CoordinateFormat.dec(
          89.99,
          style: SexagesimalStyle.plainLetters,
          seconds: SecondsPrecision.integerFloored,
        ),
        "+89° 59' 24\"",
      );
    });

    test(
      'a negative RA renders as a signed magnitude, not a floor artefact',
      () {
        // The retired helpers took `raHours.floor()` of the signed value, so
        // -0.5h printed '-1h 30m'. No production path feeds a negative RA; the
        // wrapping entry points fold it into the day instead.
        expect(
          CoordinateFormat.raHm(-0.5, style: SexagesimalStyle.plainLetters),
          '-0h 30m',
        );
        expect(
          CoordinateFormat.raHm(
            -0.5,
            style: SexagesimalStyle.plainLetters,
            wrapHours: true,
          ),
          '23h 30m',
        );
      },
    );

    test('a non-finite coordinate throws rather than printing a number', () {
      // Unchanged from the retired helpers, every one of which called
      // `.floor()` / `.round()` on the raw double. CoordinateParser.formatRaHms
      // is the NaN-safe entry point.
      expect(() => CoordinateFormat.ra(double.nan), throwsUnsupportedError);
      expect(
        () => CoordinateFormat.dec(double.infinity),
        throwsUnsupportedError,
      );
    });
  });
}
