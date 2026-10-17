import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/minor_planet_catalog.dart';
import 'package:skotiq_planetarium/src/catalogs/mpcorb.dart';

void main() {
  // A real MPCORB.DAT 1-line record for (1) Ceres, epoch K239D (2023-09-13).
  const ceresLine =
      '00001    3.34  0.12 K239D  60.07881   73.42179   80.25496   10.58688  '
      '0.0788175  0.21424651   2.7656460  0 MPO719049  7283 122 1801-2023 0.65 '
      'M-v 30h MPCLINUX   0000      (1) Ceres              20230906';

  // A real MPCORB.DAT record for (4) Vesta, epoch K239D.
  const vestaLine =
      '00004    3.20  0.32 K239D 169.20475  151.66191  103.71002    7.14181  '
      '0.0894230  0.27154654   2.3617934  0 MPO719050  6722 116 1807-2023 0.61 '
      'M-v 38h MPCLINUX   0000      (4) Vesta              20230906';

  group('MPCORB asteroid parsing', () {
    test('parses (1) Ceres orbital elements', () {
      final el = MpcOrbParser.parseAsteroidLine(ceresLine);
      expect(el, isNotNull);
      expect(el!.type, MinorBodyType.asteroid);
      expect(el.name, '1 Ceres');
      expect(el.commonName, 'Ceres');
      expect(el.semiMajorAxis, closeTo(2.7656460, 1e-5));
      expect(el.eccentricity, closeTo(0.0788175, 1e-6));
      expect(el.inclination, closeTo(10.58688, 1e-4));
      expect(el.longitudeOfNode, closeTo(80.25496, 1e-4));
      expect(el.argumentOfPerihelion, closeTo(73.42179, 1e-4));
      expect(el.meanAnomaly, closeTo(60.07881, 1e-4));
      expect(el.absoluteMag, closeTo(3.34, 1e-2));
      // K239D = 2023 Sep 13 → JD 2460200.5.
      expect(el.epoch, closeTo(2460200.5, 0.5));
    });

    test('parses a multi-record blob and skips prose header lines', () {
      final text = [
        'This is a header line that must be ignored.',
        '---------------------------------------------',
        ceresLine,
        vestaLine,
      ].join('\n');
      final list = MpcOrbParser.parseAsteroids(text);
      expect(list.length, 2);
      expect(list.map((e) => e.commonName), containsAll(['Ceres', 'Vesta']));
    });

    test('maxAbsoluteMag filters faint bodies', () {
      const text = '$ceresLine\n$vestaLine';
      final bright = MpcOrbParser.parseAsteroids(text, maxAbsoluteMag: 3.3);
      // Vesta (H 3.20) passes, Ceres (H 3.34) is filtered.
      expect(bright.map((e) => e.commonName), ['Vesta']);
    });

    test('rejects malformed lines', () {
      expect(MpcOrbParser.parseAsteroidLine('garbage'), isNull);
      expect(MpcOrbParser.parseAsteroidLine(''), isNull);
    });
  });

  group('MPC comet parsing', () {
    // Real CometEls.txt record for 1P/Halley.
    const halley =
        '0001P         1986 02  9.6671  0.587104  0.967658  111.3324   58.4204'
        '  162.2627  20240101  4.0  6.0  1P/Halley                                '
        '                20240101';

    test('parses 1P/Halley and derives a from q,e', () {
      final el = MpcOrbParser.parseCometLine(halley);
      expect(el, isNotNull);
      expect(el!.type, MinorBodyType.comet);
      expect(el.eccentricity, closeTo(0.967658, 1e-5));
      expect(el.inclination, closeTo(162.2627, 1e-3));
      // a = q / (1 - e) ≈ 0.587104 / 0.032342 ≈ 18.15.
      expect(el.semiMajorAxis, closeTo(0.587104 / (1 - 0.967658), 1e-3));
      // Perihelion-passage convention: M is 0 at the perihelion epoch.
      expect(el.meanAnomaly, 0.0);
    });

    test('skips hyperbolic / near-parabolic comets', () {
      // e >= 0.998 is beyond the elliptical propagator.
      const hyperbolic =
          '    CK23A030   2024 09 27.7299  0.391436  1.000200  308.4956   21.5617'
          '  139.1109  20240101  4.0  6.0  C/2023 A3 (Tsuchinshan-ATLAS)';
      expect(MpcOrbParser.parseCometLine(hyperbolic), isNull);
    });
  });
}
