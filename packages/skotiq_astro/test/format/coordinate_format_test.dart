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
