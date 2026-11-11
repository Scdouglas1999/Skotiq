import 'package:skotiq_astro/format.dart';
import 'package:test/test.dart';

void main() {
  group('readout', () {
    test('pads every field', () {
      expect(CoordinateFormat.raReadout(12.345), '12h 20m 42.0s');
      expect(CoordinateFormat.raReadout(5.5), '05h 30m 00.0s');
      expect(CoordinateFormat.decReadout(45.5), '+45° 30\' 00"');
      expect(CoordinateFormat.decReadout(-5.25), '-05° 15\' 00"');
    });

    test('takes degrees when the name says so', () {
      expect(CoordinateFormat.raReadoutFromDegrees(82.5), '05h 30m 00.0s');
      expect(CoordinateFormat.raReadoutFromDegrees(-7.5), '23h 30m 00.0s');
      expect(CoordinateFormat.raDenseFromDegrees(442.5), '05h30m00s');
      expect(CoordinateFormat.raCompactFromDegrees(82.5), '05h30m');
    });
  });

  group('dense and compact', () {
    test('dense keeps whole seconds', () {
      expect(CoordinateFormat.raDense(12.345), '12h20m42s');
      expect(CoordinateFormat.decDense(-45.5), '-45°30\'00"');
    });

    test('compact rounds to the minute', () {
      expect(CoordinateFormat.raCompact(5.5881), '05h35m');
      expect(CoordinateFormat.raCompact(5.5999), '05h36m');
      expect(CoordinateFormat.decCompact(22.0145), "+22°01'");
      expect(CoordinateFormat.decCompact(-89.9), "-89°54'");
    });
  });

  group('carries', () {
    // Rounding one field alone prints values that do not exist: 5.6 h has
    // 35 minutes and 59.999... seconds, which reads "05h 35m 60.0s".
    test('seconds never read 60', () {
      expect(CoordinateFormat.raReadout(5.6), '05h 36m 00.0s');
      expect(CoordinateFormat.raDense(5.99999), '06h00m00s');
      expect(CoordinateFormat.decReadout(-5.6), '-05° 36\' 00"');
      expect(CoordinateFormat.decDense(5.99999), '+06°00\'00"');
    });

    test('minutes never read 60', () {
      expect(CoordinateFormat.raCompact(5.9999), '06h00m');
      expect(CoordinateFormat.decCompact(5.9999), "+06°00'");
    });

    // The value a user typed as +42 47 00 arrives as 42.78333...; a field-wise
    // split reads it as 46' 59.99999" and printed "+42° 46' 60\"".
    test('a typed whole arcminute reads back as typed', () {
      const dec = 42 + 47 / 60;
      expect(CoordinateFormat.decReadout(dec), '+42° 47\' 00"');
      expect(CoordinateFormat.decDense(-dec), '-42°47\'00"');
      expect(CoordinateFormat.decCompact(dec), "+42°47'");
    });

    test('seconds of arc carry at every rounding boundary', () {
      double dec(int d, int m, double s) => d + m / 60 + s / 3600;
      expect(CoordinateFormat.decReadout(dec(10, 20, 59.95)), '+10° 21\' 00"');
      expect(CoordinateFormat.decReadout(dec(10, 20, 59.995)), '+10° 21\' 00"');
      expect(CoordinateFormat.decReadout(dec(10, 20, 59.49)), '+10° 20\' 59"');
      expect(CoordinateFormat.decReadout(dec(10, 59, 59.96)), '+11° 00\' 00"');
      expect(
        CoordinateFormat.decReadout(-dec(10, 59, 59.96)),
        '-11° 00\' 00"',
      );
      expect(CoordinateFormat.decDense(dec(89, 59, 59.96)), '+90°00\'00"');
    });

    test('seconds of time carry at every rounding boundary', () {
      double ra(int h, int m, double s) => h + m / 60 + s / 3600;
      expect(CoordinateFormat.raReadout(ra(2, 42, 59.95)), '02h 43m 00.0s');
      expect(CoordinateFormat.raReadout(ra(2, 42, 59.94)), '02h 42m 59.9s');
      expect(CoordinateFormat.raReadout(ra(2, 59, 59.96)), '03h 00m 00.0s');
      expect(CoordinateFormat.raDense(ra(2, 59, 59.5)), '03h00m00s');
      expect(CoordinateFormat.raReadout(ra(23, 59, 59.96)), '00h 00m 00.0s');
      expect(CoordinateFormat.raDense(ra(23, 59, 59.96)), '00h00m00s');
      expect(CoordinateFormat.raCompact(ra(23, 59, 59.96)), '00h00m');
    });
  });

  group('right ascension folds into one day', () {
    test('a negative or over-range hour is a real time of day', () {
      expect(CoordinateFormat.raReadout(24.0), '00h 00m 00.0s');
      expect(CoordinateFormat.raReadout(25.5), '01h 30m 00.0s');
      expect(CoordinateFormat.raReadout(-0.5), '23h 30m 00.0s');
      expect(CoordinateFormat.raCompact(-0.005), '00h00m');
      expect(CoordinateFormat.raCompact(-0.01), '23h59m');
    });

    test('rounding up at the end of the day reads zero, not 24h', () {
      expect(CoordinateFormat.raReadout(23.99999999), '00h 00m 00.0s');
      expect(CoordinateFormat.raDense(23.99999), '00h00m00s');
      expect(CoordinateFormat.raCompact(23.9999), '00h00m');
    });
  });

  test('a non-finite coordinate reads as unknown', () {
    expect(CoordinateFormat.raReadout(double.nan), '—');
    expect(CoordinateFormat.decDense(double.infinity), '—');
    expect(CoordinateFormat.raCompactFromDegrees(double.nan), '—');
  });
}
