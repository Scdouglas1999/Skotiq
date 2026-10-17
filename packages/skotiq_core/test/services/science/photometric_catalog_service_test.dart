import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('PhotometricCatalogService.parseVizierTsv', () {
    // Captured verbatim from a live VizieR asu-tsv response for
    // II/336/apass9 (2026-06-10) — pins the parser to the real wire format:
    // '#' comment preamble, tab-separated header, a units row, a dashed
    // separator, then data rows with signed declinations.
    const sample = '''
#
#   VizieR Astronomical Server vizier.cds.unistra.fr
#    Date: 2026-06-10T23:03:27 [V7.5.6]
#INFO\tservice_protocol=ASU\tIVOID of the protocol
#Constraint Vmag=>0

RAJ2000\tDEJ2000\tVmag\tBmag
deg\tdeg\tmag\tmag
----------\t----------\t------\t------
132.941947\t+11.604885\t11.166\t11.864
132.960939\t+11.609457\t13.431\t13.902
132.947126\t+11.611769\t16.081\t16.957
132.866310\t-11.582620\t14.980\t
''';

    test('parses data rows, units row, and missing Bmag', () {
      final stars = PhotometricCatalogService.parseVizierTsv(sample);
      expect(stars, hasLength(4));

      expect(stars[0].raDegrees, closeTo(132.941947, 1e-9));
      expect(stars[0].decDegrees, closeTo(11.604885, 1e-9));
      expect(stars[0].magV, closeTo(11.166, 1e-9));
      // B-V from APASS B and V.
      expect(stars[0].colorIndexBv, closeTo(11.864 - 11.166, 1e-9));

      // Signed negative declination.
      expect(stars[3].decDegrees, closeTo(-11.582620, 1e-9));
      // Missing Bmag -> no color index, star still usable for ZP work.
      expect(stars[3].colorIndexBv, isNull);
    });

    test('returns empty for a header-only or garbage body', () {
      expect(PhotometricCatalogService.parseVizierTsv(''), isEmpty);
      expect(
        PhotometricCatalogService.parseVizierTsv('#nothing\n#here\n'),
        isEmpty,
      );
      expect(
        PhotometricCatalogService.parseVizierTsv('<html>error page</html>'),
        isEmpty,
      );
    });
  });

  group('PhotometricCatalogService.bvFromSpectralType', () {
    test('interpolates within spectral class', () {
      // G2 sits 2/10 of the way from G0 (+0.58) to K0 (+0.81).
      expect(
        PhotometricCatalogService.bvFromSpectralType('G2V'),
        closeTo(0.58 + (0.81 - 0.58) * 0.2, 1e-9),
      );
      expect(
        PhotometricCatalogService.bvFromSpectralType('A0'),
        closeTo(0.0, 1e-9),
      );
    });

    test('rejects unparseable types', () {
      expect(PhotometricCatalogService.bvFromSpectralType(''), isNull);
      expect(PhotometricCatalogService.bvFromSpectralType('X9'), isNull);
    });
  });
}
