import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

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

  group('CoordinateFormat reads back through the strict parser', () {
    // The app fills coordinate fields with these strings, and the parser
    // rejects an impossible value such as 23:59:60, so every shape has to be
    // one the parser accepts for every input.
    test('every shape of RA', () {
      for (var i = 0; i < 2400; i++) {
        final ra = i * 0.01;
        for (final formatted in <String>[
          CoordinateFormat.raReadout(ra),
          CoordinateFormat.raDense(ra),
          CoordinateFormat.raCompact(ra),
        ]) {
          expect(
            CoordinateParser.parseRa(formatted),
            isNotNull,
            reason: '$ra h formats as "$formatted"',
          );
        }
      }
    });

    test('every shape of Dec', () {
      for (var i = -8900; i <= 8900; i += 7) {
        final dec = i * 0.01;
        for (final formatted in <String>[
          CoordinateFormat.decReadout(dec),
          CoordinateFormat.decDense(dec),
          CoordinateFormat.decCompact(dec),
        ]) {
          expect(
            CoordinateParser.parseDec(formatted),
            isNotNull,
            reason: '$dec deg formats as "$formatted"',
          );
        }
      }
    });

    test('the readout keeps its precision through a round trip', () {
      expect(
        CoordinateParser.parseRa(CoordinateFormat.raReadout(5.5881)),
        closeTo(5.5881, 0.1 / 3600),
      );
      expect(
        CoordinateParser.parseDec(CoordinateFormat.decReadout(-5.3911)),
        closeTo(-5.3911, 1 / 3600),
      );
    });
  });
}
