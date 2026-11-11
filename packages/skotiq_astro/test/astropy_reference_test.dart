// Holds every ephemeris in this package to an independent reference: a grid of
// instants, sites and targets computed with astropy
// (tool/gen_astropy_reference.py). The tolerances are the measured worst case
// over the grid plus a small margin, so a formula edit that moves a number
// shows up here as a number, not as a changed golden.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

double _wrap180(double degrees) {
  var v = (degrees + 180) % 360;
  if (v < 0) v += 360;
  return v - 180;
}

void main() {
  final reference =
      jsonDecode(
            File('test/reference/astropy_reference.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final sites = (reference['sites'] as List).cast<Map<String, dynamic>>();
  final targets = (reference['targets'] as List).cast<Map<String, dynamic>>();
  final instants = (reference['instants'] as List).cast<Map<String, dynamic>>();
  final twilight = (reference['twilight'] as List).cast<Map<String, dynamic>>();

  double n(Object? v) => (v as num).toDouble();

  test('the reference grid is the size the tolerances were measured on', () {
    expect(instants.length, 64);
    expect(sites.length, 7);
    expect(targets.length, 12);
    expect(twilight.length, 84);
  });

  test('Julian Date matches to a tenth of a millisecond', () {
    for (final rec in instants) {
      final t = DateTime.parse(rec['utc'] as String);
      expect(
        AstronomyCalculations.julianDate(t),
        closeTo(n(rec['jd']), 1e-9),
        reason: rec['utc'] as String,
      );
    }
  });

  test('mean sidereal time matches to 10 ms', () {
    for (final rec in instants) {
      final t = DateTime.parse(rec['utc'] as String);
      final gmst = AstronomyCalculations.greenwichMeanSiderealTime(t);
      final seconds = _wrap180((gmst - n(rec['gmst_h'])) * 15) / 15 * 3600;
      expect(seconds.abs(), lessThan(0.01), reason: rec['utc'] as String);
    }
  });

  test('the Sun is within an arcminute and 0.02 degrees of altitude', () {
    for (final rec in instants) {
      final t = DateTime.parse(rec['utc'] as String);
      final sun = rec['sun'] as Map<String, dynamic>;
      final (ra, dec) = AstronomyCalculations.sunPosition(t);
      final dRa =
          _wrap180(ra - n(sun['ra'])) * 3600 * math.cos(dec * math.pi / 180);
      expect(dRa.abs(), lessThan(60), reason: 'RA ${rec['utc']}');
      expect(
        ((dec - n(sun['dec'])) * 3600).abs(),
        lessThan(30),
        reason: 'Dec ${rec['utc']}',
      );
      final perSite = (rec['per_site'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < sites.length; i++) {
        final (alt, az) = AstronomyCalculations.sunAltAz(
          dt: t,
          latitudeDeg: n(sites[i]['lat']),
          longitudeDeg: n(sites[i]['lon']),
        );
        final refAlt = n(perSite[i]['sun_alt']);
        final where = '${rec['utc']} ${sites[i]['name']}';
        expect(alt, closeTo(refAlt, 0.02), reason: where);
        final dAz =
            _wrap180(az - n(perSite[i]['sun_az'])) *
            math.cos(refAlt * math.pi / 180);
        expect(dAz.abs(), lessThan(0.02), reason: where);
      }
    }
  });

  test('the Moon is within 0.3 degrees, 1500 km and 0.4 points of phase', () {
    for (final rec in instants) {
      final t = DateTime.parse(rec['utc'] as String);
      final moon = rec['moon'] as Map<String, dynamic>;
      final (ra, dec, distance) = AstronomyCalculations.moonPosition(t);
      expect(
        AstronomyCalculations.angularSeparation(
          ra1Deg: ra,
          dec1Deg: dec,
          ra2Deg: n(moon['ra']),
          dec2Deg: n(moon['dec']),
        ),
        lessThan(0.3),
        reason: rec['utc'] as String,
      );
      expect(distance, closeTo(n(moon['dist_km']), 1500));
      expect(
        AstronomyCalculations.moonIllumination(t),
        closeTo(n(moon['illum_pct']), 0.4),
        reason: rec['utc'] as String,
      );
    }
  });

  test('a J2000 target lands within 0.015 degrees in altitude and azimuth', () {
    for (final rec in instants) {
      final t = DateTime.parse(rec['utc'] as String);
      final perSite = (rec['per_site'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < sites.length; i++) {
        final refs = perSite[i]['targets'] as List;
        for (var k = 0; k < targets.length; k++) {
          final (alt, az) = AstronomyCalculations.objectAltAz(
            raDeg: n(targets[k]['ra']),
            decDeg: n(targets[k]['dec']),
            dt: t,
            latitudeDeg: n(sites[i]['lat']),
            longitudeDeg: n(sites[i]['lon']),
          );
          final refAlt = n((refs[k] as List)[0]);
          final refAz = n((refs[k] as List)[1]);
          final where =
              '${rec['utc']} ${sites[i]['name']} ${targets[k]['name']}';
          expect(alt, closeTo(refAlt, 0.015), reason: where);
          final dAz = _wrap180(az - refAz) * math.cos(refAlt * math.pi / 180);
          expect(dAz.abs(), lessThan(0.015), reason: where);
        }
      }
    }
  });

  group('twilight', () {
    final siteByName = {for (final s in sites) s['name'] as String: s};

    void expectEvent(DateTime? got, Object? want, int seconds, String where) {
      if (want == null) {
        expect(got, isNull, reason: where);
        return;
      }
      expect(got, isNotNull, reason: where);
      final delta = got!.difference(DateTime.parse(want as String));
      expect(delta.inSeconds.abs(), lessThanOrEqualTo(seconds), reason: where);
    }

    void expectNight(TwilightTimes times, Map<String, dynamic> ev, String w) {
      expectEvent(times.sunset, ev['sun_dusk'], 12, 'sunset $w');
      expectEvent(times.sunrise, ev['sun_dawn'], 12, 'sunrise $w');
      for (final kind in TwilightKind.values) {
        expectEvent(
          times.dusk(kind),
          ev['${kind.name}_dusk'],
          10,
          '${kind.name} dusk $w',
        );
        expectEvent(
          times.dawn(kind),
          ev['${kind.name}_dawn'],
          10,
          '${kind.name} dawn $w',
        );
      }
    }

    test('by calendar date: every event within 12 s, and missing when the '
        'Sun never gets there', () {
      for (final ev in twilight) {
        final site = siteByName[ev['site']]!;
        final date = DateTime.parse(ev['date'] as String);
        final times = AstronomyCalculations.calculateTwilightTimes(
          date: DateTime(date.year, date.month, date.day),
          latitudeDeg: n(site['lat']),
          longitudeDeg: n(site['lon']),
        );
        expectNight(times, ev, '${ev['date']} ${ev['site']}');
      }
    });

    test('by instant: the night after the nearest solar noon, UTC in and '
        'UTC out', () {
      for (final ev in twilight) {
        final site = siteByName[ev['site']]!;
        final noon = DateTime.parse(ev['solar_noon_utc'] as String);
        for (final offset in const [
          Duration(hours: -11),
          Duration.zero,
          Duration(hours: 11),
        ]) {
          final times = AstronomyCalculations.twilightTimesNear(
            instant: noon.add(offset),
            latitudeDeg: n(site['lat']),
            longitudeDeg: n(site['lon']),
          );
          expectNight(times, ev, '${ev['date']} ${ev['site']} $offset');
          expect(times.sunset?.isUtc ?? true, isTrue);
        }
      }
    });
  });
}
