import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Cross-validation of the pure-Dart HEALPix NESTED math against an
/// authoritative independent reference: `astropy_healpix` 1.1.2.
///
/// The fixture `healpix_reference.json` is generated from astropy_healpix
/// (see the generator note below) and pins ang->pix, pix->ang(center), and
/// cell-boundary corner positions across orders 0..10 at sky points that
/// span all latitudes including the polar caps and the base-face seams.
/// This guards the implementation against subtle face/longitude convention
/// drift that the self-consistency suite alone could miss.
///
/// Regenerate with (Python, astropy_healpix installed):
///   from astropy_healpix import HEALPix; import astropy.units as u
///   hp = HEALPix(nside=2**order, order='nested')
///   hp.lonlat_to_healpix(ra*u.deg, dec*u.deg)        # ang -> pix
///   hp.healpix_to_lonlat([ipix])                      # pix -> center
///   hp.boundaries_lonlat([ipix], step=1)             # 4 corners
void main() {
  late Map<String, dynamic> ref;

  setUpAll(() {
    final file = File('test/services/hips/healpix_reference.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'reference fixture must be present at ${file.absolute.path}',
    );
    ref = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('ang2pixNest matches astropy_healpix exactly', () {
    final cases = (ref['ang2pix'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    var checked = 0;
    for (final c in cases) {
      final order = c['order'] as int;
      final ra = (c['ra'] as num).toDouble();
      final dec = (c['dec'] as num).toDouble();
      final expected = c['ipix'] as int;
      final h = HealpixNested(order);
      expect(
        h.ang2pixNest(ra, dec),
        expected,
        reason: 'order $order ra=$ra dec=$dec',
      );
      checked++;
    }
    expect(checked, greaterThan(1000));
  });

  test('pix2ang centers match astropy_healpix to sub-arcsecond', () {
    final cases = (ref['pix2ang'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final order = c['order'] as int;
      final ipix = c['ipix'] as int;
      final ra = (c['ra'] as num).toDouble();
      final dec = (c['dec'] as num).toDouble();
      final h = HealpixNested(order);
      final got = h.pix2RaDec(ipix);
      final sep = _angularSepDeg(ra, dec, got.raDeg, got.decDeg);
      // 1e-5 deg = 36 milli-arcsec. The residual vs astropy is pure
      // floating-point trig round-off (a different acos/atan2 evaluation
      // order), not an algorithmic difference: it is ~1.2e-6 deg and
      // independent of order, far below any HiPS pixel scale.
      expect(
        sep,
        lessThan(1e-5),
        reason: 'order $order ipix $ipix sep=${sep}deg',
      );
    }
  });

  test('boundaries corners match astropy_healpix (as a set)', () {
    // astropy and this implementation may label the four corners starting
    // from a different vertex / winding, so compare the corner *sets*, each
    // corner matched to its nearest reference corner within tight tolerance.
    final cases = (ref['boundaries'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final order = c['order'] as int;
      final ipix = c['ipix'] as int;
      final ras = (c['ras'] as List).cast<num>().map((e) => e.toDouble());
      final decs = (c['decs'] as List).cast<num>().map((e) => e.toDouble());
      final refCorners = [
        for (final (i, ra) in ras.indexed) (ra: ra, dec: decs.elementAt(i)),
      ];
      final h = HealpixNested(order);
      final got = h
          .boundaries(ipix)
          .map((a) => (ra: a.raDeg, dec: a.decDeg))
          .toList();
      expect(got.length, 4);
      for (final g in got) {
        // Each Dart corner must coincide with some reference corner.
        var best = double.infinity;
        for (final r in refCorners) {
          final s = _angularSepDeg(g.ra, g.dec, r.ra, r.dec);
          if (s < best) best = s;
        }
        expect(
          best,
          lessThan(1e-5),
          reason: 'order $order ipix $ipix corner ($g) unmatched',
        );
      }
    }
  });

  test('neighboursNest matches astropy_healpix (as a set)', () {
    // astropy returns neighbours starting SW rotating clockwise
    // ([SW, W, NW, N, NE, E, SE, S]); this implementation starts at W
    // ([W, NW, N, NE, E, SE, S, SW]). The two are rotations of the same
    // cyclic sequence, so compare the neighbour *sets* (both use -1 for the
    // missing neighbour at base-face corners).
    final cases = (ref['neighbours'] as List).cast<Map<String, dynamic>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final order = c['order'] as int;
      final ipix = c['ipix'] as int;
      final expected = (c['neighbours'] as List)
          .cast<num>()
          .map((e) => e.toInt())
          .toSet();
      final h = HealpixNested(order);
      final got = h.neighboursNest(ipix).toSet();
      expect(got, expected, reason: 'order $order ipix $ipix');
    }
  });
}

double _angularSepDeg(double ra1, double dec1, double ra2, double dec2) {
  final r1 = ra1 * math.pi / 180.0;
  final d1 = dec1 * math.pi / 180.0;
  final r2 = ra2 * math.pi / 180.0;
  final d2 = dec2 * math.pi / 180.0;
  final v1x = math.cos(d1) * math.cos(r1);
  final v1y = math.cos(d1) * math.sin(r1);
  final v1z = math.sin(d1);
  final v2x = math.cos(d2) * math.cos(r2);
  final v2y = math.cos(d2) * math.sin(r2);
  final v2z = math.sin(d2);
  final dot = (v1x * v2x + v1y * v2y + v1z * v2z).clamp(-1.0, 1.0);
  return math.acos(dot) * 180.0 / math.pi;
}
