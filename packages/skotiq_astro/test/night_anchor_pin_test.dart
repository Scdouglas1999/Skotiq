import 'dart:convert';
import 'dart:io';

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

/// Rise, set, twilight and dark-window values for three sites on five dates,
/// recorded on a computer set to each site's own time zone.
///
/// Every value is an instant, so the same table must come out on a computer in
/// any zone. Run this file under several `TZ` values.
///
/// To record the table, run once per site zone with
/// `NIGHT_ANCHOR_PIN_WRITE=1 TZ=<site zone>`; each run rewrites only the rows
/// of the sites in that zone.
void main() {
  final fixture = File('test/fixtures/night_anchor_pins.json');
  final writeZone = Platform.environment['NIGHT_ANCHOR_PIN_WRITE'] == '1'
      ? Platform.environment['TZ']
      : null;

  if (writeZone != null) {
    test('records the rows for $writeZone', () {
      final rows = fixture.existsSync()
          ? (jsonDecode(fixture.readAsStringSync()) as List)
                .cast<Map<String, Object?>>()
                .where((row) => row['zone'] != writeZone)
                .toList()
          : <Map<String, Object?>>[];
      for (final site in _sites.where((s) => s.zone == writeZone)) {
        for (final (y, m, d) in _dates) {
          for (final c in _casesFor(site, y, m, d)) {
            rows.add({...c.input, 'expected': c.compute()});
          }
        }
      }
      fixture.writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert(rows),
      );
    });
    return;
  }

  final rows = (jsonDecode(fixture.readAsStringSync()) as List)
      .cast<Map<String, Object?>>();
  final sites = {for (final s in _sites) s.name: s};
  for (final row in rows) {
    final site = sites[row['site']]!;
    final c = _caseFromInput(site, row);
    test(c.label, () {
      final actual = c.compute();
      final expected = (row['expected']! as Map).cast<String, Object?>();
      expect(actual.keys.toSet(), expected.keys.toSet());
      for (final key in expected.keys) {
        final want = expected[key];
        final got = actual[key];
        if (want is int && got is int && key.endsWith('Ms')) {
          expect(
            (got - want).abs(),
            lessThanOrEqualTo(_toleranceMs),
            reason:
                '$key: got ${_iso(got)}, pinned ${_iso(want)} '
                '(${(got - want) / 1000} s)',
          );
        } else {
          expect(got, want, reason: key);
        }
      }
    });
  }
}

/// The crossings are bisected to about a second on a five-minute sample
/// grid; moving the grid moves the answer by up to a couple of seconds.
const _toleranceMs = 5000;

String _iso(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

typedef _Site = ({String name, String zone, double lat, double lon});

const List<_Site> _sites = [
  (name: 'new-york', zone: 'America/New_York', lat: 40.7128, lon: -74.0060),
  (name: 'madrid', zone: 'Europe/Madrid', lat: 40.4168, lon: -3.7038),
  (name: 'tokyo', zone: 'Asia/Tokyo', lat: 35.6762, lon: 139.6503),
];

const _dates = [
  (2026, 1, 15),
  (2026, 3, 8),
  (2026, 6, 21),
  (2026, 11, 1),
  (2026, 11, 22),
];

const _objectRas = [0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330];
const _objectDecs = [60, 20, -20];

/// Wall-clock instants on the night's date (hours past its midnight) at
/// which the instant-taking entry points are read.
const _instantHours = [
  10.0,
  11.0,
  11.5,
  12.0,
  12.5,
  13.0,
  13.5,
  14.0,
  14.5,
  15.0,
  23.0,
  27.0,
];

class _Case {
  final String label;
  final Map<String, Object?> input;
  final Map<String, Object?> Function() compute;
  _Case(this.label, this.input, this.compute);
}

List<_Case> _casesFor(_Site site, int y, int m, int d) {
  final date = '$y-${_two(m)}-${_two(d)}';
  final base = {'site': site.name, 'zone': site.zone, 'date': date};
  final cases = <_Case>[
    _caseFromInput(site, {...base, 'kind': 'twilight'}),
    _caseFromInput(site, {...base, 'kind': 'sun'}),
    _caseFromInput(site, {...base, 'kind': 'moon'}),
    _caseFromInput(site, {...base, 'kind': 'moonTimes'}),
  ];
  for (final ra in _objectRas) {
    for (final dec in _objectDecs) {
      cases.add(
        _caseFromInput(site, {...base, 'kind': 'object', 'ra': ra, 'dec': dec}),
      );
    }
    cases.add(
      _caseFromInput(site, {...base, 'kind': 'around', 'ra': ra, 'dec': 20}),
    );
  }
  for (final hours in _instantHours) {
    final instant = DateTime(
      y,
      m,
      d,
    ).add(Duration(minutes: (hours * 60).round()));
    final ms = instant.millisecondsSinceEpoch;
    cases.add(
      _caseFromInput(site, {...base, 'kind': 'nightDate', 'instantMs': ms}),
    );
    cases.add(
      _caseFromInput(site, {...base, 'kind': 'darkWindow', 'instantMs': ms}),
    );
  }
  return cases;
}

String _two(int v) => v.toString().padLeft(2, '0');

_Case _caseFromInput(_Site site, Map<String, Object?> input) {
  final parts = (input['date']! as String).split('-').map(int.parse).toList();
  final date = DateTime(parts[0], parts[1], parts[2]);
  final kind = input['kind']! as String;
  final label = [
    site.name,
    input['date'],
    kind,
    if (input['ra'] != null) 'ra=${input['ra']} dec=${input['dec']}',
    if (input['instantMs'] != null) 'at ${_iso(input['instantMs']! as int)}',
  ].join(' ');

  Map<String, Object?> compute() {
    switch (kind) {
      case 'twilight':
        return _twilightJson(
          AstronomyCalculations.calculateTwilightTimes(
            date: NightDate.ofCalendarDay(date),
            latitudeDeg: site.lat,
            longitudeDeg: site.lon,
          ),
        );
      case 'sun':
        return _visibilityJson(
          AstronomyCalculations.calculateSunVisibility(
            date: date,
            latitudeDeg: site.lat,
            longitudeDeg: site.lon,
          ),
        );
      case 'moon':
        return _visibilityJson(
          AstronomyCalculations.calculateMoonVisibility(
            date: date,
            latitudeDeg: site.lat,
            longitudeDeg: site.lon,
          ),
        );
      case 'moonTimes':
        final t = AstronomyCalculations.calculateMoonTimes(
          date: date,
          latitudeDeg: site.lat,
          longitudeDeg: site.lon,
        );
        return {
          'moonriseMs': t.moonrise?.millisecondsSinceEpoch,
          'moonsetMs': t.moonset?.millisecondsSinceEpoch,
        };
      case 'object':
        return _visibilityJson(
          AstronomyCalculations.calculateObjectVisibility(
            raDeg: (input['ra']! as int).toDouble(),
            decDeg: (input['dec']! as int).toDouble(),
            date: NightDate.ofCalendarDay(date),
            latitudeDeg: site.lat,
            longitudeDeg: site.lon,
          ),
        );
      case 'around':
        return _visibilityJson(
          AstronomyCalculations.calculateObjectVisibilityAround(
            raDeg: (input['ra']! as int).toDouble(),
            decDeg: (input['dec']! as int).toDouble(),
            center: _nightMiddle(date, site),
            latitudeDeg: site.lat,
            longitudeDeg: site.lon,
          ),
        );
      case 'nightDate':
        final night = AstronomyCalculations.nightDateOf(
          DateTime.fromMillisecondsSinceEpoch(input['instantMs']! as int),
          longitudeDeg: site.lon,
        );
        return {
          'nightDate': '${night.year}-${_two(night.month)}-${_two(night.day)}',
        };
      case 'darkWindow':
        final window = AstronomyCalculations.darkWindow(
          now: DateTime.fromMillisecondsSinceEpoch(input['instantMs']! as int),
          latitudeDeg: site.lat,
          longitudeDeg: site.lon,
        );
        return switch (window) {
          NightDarkWindow(:final start, :final end) => {
            'startMs': start.millisecondsSinceEpoch,
            'endMs': end.millisecondsSinceEpoch,
          },
          NoDarkWindow(:final polarNight) => {'polarNight': polarNight},
        };
    }
    throw ArgumentError(kind);
  }

  return _Case(label, input, compute);
}

/// The middle of the night of [date], as the callers that center a search on
/// it build it.
DateTime _nightMiddle(DateTime date, _Site site) =>
    AstronomyCalculations.nightMiddleOf(
      NightDate.ofCalendarDay(date),
      longitudeDeg: site.lon,
    );

Map<String, Object?> _twilightJson(TwilightTimes t) => {
  'sunsetMs': t.sunset?.millisecondsSinceEpoch,
  'civilDuskMs': t.civilDusk?.millisecondsSinceEpoch,
  'nauticalDuskMs': t.nauticalDusk?.millisecondsSinceEpoch,
  'astronomicalDuskMs': t.astronomicalDusk?.millisecondsSinceEpoch,
  'astronomicalDawnMs': t.astronomicalDawn?.millisecondsSinceEpoch,
  'nauticalDawnMs': t.nauticalDawn?.millisecondsSinceEpoch,
  'civilDawnMs': t.civilDawn?.millisecondsSinceEpoch,
  'sunriseMs': t.sunrise?.millisecondsSinceEpoch,
};

Map<String, Object?> _visibilityJson(ObjectVisibility v) => {
  'riseMs': v.riseTime?.millisecondsSinceEpoch,
  'transitMs': v.transitTime?.millisecondsSinceEpoch,
  'setMs': v.setTime?.millisecondsSinceEpoch,
  'circumpolar': v.isCircumpolar,
  'neverRises': v.neverRises,
};
