// The altitude floor answers the shared cases in
// test_fixtures/altitude_floor/cases.json, which the run's native
// AltitudeFloor answers too (scheduling/altitude_floor.rs).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

const _fixturePath = '../../test_fixtures/altitude_floor/cases.json';

AltitudeFloor _floor(Map<String, dynamic> spec) {
  final horizon = spec['horizon'] as List<dynamic>?;
  return AltitudeFloor(
    horizon: horizon == null
        ? SiteHorizonProfile.fromJson('{}')
        : SiteHorizonProfile.fromSamples([
            for (final point in horizon.cast<Map<String, dynamic>>())
              (
                azimuth: (point['az'] as num).toDouble(),
                altitude: (point['alt'] as num).toDouble(),
              ),
          ]),
    minimumDeg: (spec['minimum'] as num).toDouble(),
  );
}

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

void main() {
  final file = File(_fixturePath);
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final site = fixture['site'] as Map<String, dynamic>;
  final latitude = (site['latitude'] as num).toDouble();
  final longitude = (site['longitude'] as num).toDouble();
  final specs = (fixture['floors'] as Map<String, dynamic>)
      .cast<String, Map<String, dynamic>>();
  final floors = {
    for (final entry in specs.entries) entry.key: _floor(entry.value),
  };
  final tolerance = Duration(
    seconds: fixture['crossing_tolerance_secs'] as int,
  );

  Map<String, Object?> answers(Map<String, dynamic> c, String kind) {
    final floor = floors[c['floor']]!;
    switch (kind) {
      case 'at_azimuth':
        return {
          'expect': floor.atAzimuth((c['azimuth'] as num).toDouble()),
        };
      case 'above':
        return {
          'expect': floor.isAbove(
            raDeg: (c['ra_hours'] as num) * 15.0,
            decDeg: (c['dec_degrees'] as num).toDouble(),
            at: DateTime.parse(c['at'] as String),
            latitudeDeg: latitude,
            longitudeDeg: longitude,
          ),
        };
      default:
        final from = DateTime.parse(c['from'] as String);
        final until = DateTime.parse(c['until'] as String);
        DateTime? first(bool above) => (above
            ? floor.risesAbove
            : floor.setsBelow)(
          raDeg: (c['ra_hours'] as num) * 15.0,
          decDeg: (c['dec_degrees'] as num).toDouble(),
          from: from,
          until: until,
          latitudeDeg: latitude,
          longitudeDeg: longitude,
        );
        return {
          'rises_above': _iso(first(true)),
          'sets_below': _iso(first(false)),
        };
    }
  }

  // Maintenance: write this side's answers into the fixture.
  if (Platform.environment['ALTITUDE_FLOOR_FIXTURE_WRITE'] == '1') {
    test('writes the fixture', () {
      for (final entry in specs.entries) {
        entry.value['wire'] = floors[entry.key]!.toWire();
      }
      for (final kind in ['at_azimuth', 'above', 'crossings']) {
        for (final c in (fixture[kind] as List).cast<Map<String, dynamic>>()) {
          c.addAll(answers(c, kind));
        }
      }
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(fixture)}\n',
      );
    });
    return;
  }

  test('the floor sent to the run is the fixture\'s wire form', () {
    for (final entry in specs.entries) {
      expect(
        jsonEncode(floors[entry.key]!.toWire()),
        jsonEncode(entry.value['wire']),
        reason: entry.key,
      );
    }
  });

  test('a horizon replaces the minimum altitude; with none the minimum '
      'holds in every direction', () {
    expect(floors['tree_line']!.followsHorizon, isTrue);
    expect(floors['tree_line']!.atAzimuth(270), 0);
    expect(floors['minimum']!.followsHorizon, isFalse);
    expect(floors['minimum']!.atAzimuth(270), 30);
  });

  test('the floor toward an azimuth', () {
    for (final c in (fixture['at_azimuth'] as List)
        .cast<Map<String, dynamic>>()) {
      expect(
        answers(c, 'at_azimuth')['expect'],
        closeTo((c['expect'] as num).toDouble(), 1e-6),
        reason: '$c',
      );
    }
  });

  test('whether a target is above the floor where it stands', () {
    for (final c in (fixture['above'] as List).cast<Map<String, dynamic>>()) {
      expect(answers(c, 'above')['expect'], c['expect'], reason: '$c');
    }
  });

  test('when a target rises above and sets below the floor', () {
    for (final c in (fixture['crossings'] as List)
        .cast<Map<String, dynamic>>()) {
      final got = answers(c, 'crossings');
      for (final key in ['rises_above', 'sets_below']) {
        final expected = c[key] as String?;
        final actual = got[key] as String?;
        if (expected == null || actual == null) {
          expect(actual, expected, reason: '$key of $c');
        } else {
          expect(
            DateTime.parse(actual).difference(DateTime.parse(expected)).abs(),
            lessThanOrEqualTo(tolerance),
            reason: '$key of $c',
          );
        }
      }
    }
  });

  test('an eastern target waits for the tree line and a western one does '
      'not', () {
    final night = DateTime.utc(2026, 1, 15, 3);
    bool above(String floor, double raHours) => floors[floor]!.isAbove(
      raDeg: raHours * 15.0,
      decDeg: 20,
      at: night,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );
    expect(above('tree_line', 10), isFalse);
    expect(above('tree_line', 1.5), isTrue);
    final clears = floors['tree_line']!.risesAbove(
      raDeg: 150,
      decDeg: 20,
      from: night,
      until: night.add(const Duration(hours: 8)),
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );
    expect(clears, isNotNull);
    expect(clears!.isAfter(night.add(const Duration(minutes: 10))), isTrue);
  });

  test('a target\'s own minimum is added to the floor, never taken from '
      'it', () {
    final floor = floors['tree_line']!;
    expect(floor.forTargetMinimum(50).atAzimuth(90), 50);
    expect(floor.forTargetMinimum(20).atAzimuth(90), 40);
    expect(floor.forTargetMinimum(20).atAzimuth(270), 20);
    expect(floor.forTargetMinimum(null).atAzimuth(270), 0);
  });

  test('a step reading that begins "Waiting for " is a target waiting to '
      'start', () {
    const waiting =
        'Waiting for East to clear the altitude floor: 35° up, floor 40° in '
        'that direction';
    expect(targetWaitMessage(waiting), waiting);
    expect(targetWaitMessage('Waiting for East: time ≥ 12'), isNotNull);
    expect(targetWaitMessage('Started'), isNull);
    expect(targetWaitMessage(null), isNull);
  });
}
