// Which night an altitude chart plots, every 20 minutes over two days at four
// sites, pinned in fixtures/altitude_chart_night_pick.json. The rows were
// recorded with each site's computer in the site's own zone; the chart must
// pick the same night on a computer in any zone. Record a site's rows with
// SKOTIQ_RECORD_NIGHT_PICK=1 and TZ set to that site's zone.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/altitude_chart.dart';

typedef _Site = ({String name, String zone, double latitude, double longitude});

const _sites = <_Site>[
  (
    name: 'New York',
    zone: 'America/New_York',
    latitude: 40.7128,
    longitude: -74.0060,
  ),
  (
    name: 'Los Angeles',
    zone: 'America/Los_Angeles',
    latitude: 34.0522,
    longitude: -118.2437,
  ),
  (name: 'Tokyo', zone: 'Asia/Tokyo', latitude: 35.6762, longitude: 139.6503),
  (
    name: 'Madrid',
    zone: 'Europe/Madrid',
    latitude: 40.4168,
    longitude: -3.7038
  ),
];

final _fixture = File('test/widgets/fixtures/altitude_chart_night_pick.json');

/// Instants every 20 minutes over two UTC days around [day].
Iterable<DateTime> _sweep(DateTime day) sync* {
  for (var m = 0; m < 2 * 24 * 60; m += 20) {
    yield day.add(Duration(minutes: m));
  }
}

final _days = [DateTime.utc(2026, 11, 21), DateTime.utc(2026, 6, 20)];

Map<String, String?> _rowsOf(_Site site) => {
      for (final day in _days)
        for (final instant in _sweep(day))
          instant.toIso8601String(): altitudeChartNight(
            instant.toLocal(),
            latitudeDeg: site.latitude,
            longitudeDeg: site.longitude,
          ).sunset?.toUtc().toIso8601String(),
    };

void main() {
  final record = Platform.environment['SKOTIQ_RECORD_NIGHT_PICK'] == '1';
  final zone = Platform.environment['TZ'];

  if (record) {
    test('record the rows of the site in this zone', () {
      final all = _fixture.existsSync()
          ? jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>
          : <String, Object?>{};
      for (final site in _sites.where((s) => s.zone == zone)) {
        all[site.name] = _rowsOf(site);
      }
      _fixture.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(all)}\n',
      );
    });
    return;
  }

  final pinned =
      jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;
  for (final site in _sites) {
    test(
        '${site.name}: the plotted night is the one the site\'s own '
        'computer plots', () {
      final expected = Map<String, Object?>.from(pinned[site.name]! as Map);
      final actual = _rowsOf(site);
      final differing = [
        for (final key in expected.keys)
          if (actual[key] != expected[key])
            '$key: ${actual[key]} (pinned ${expected[key]})',
      ];
      expect(differing, isEmpty);
      expect(actual.keys.toSet(), expected.keys.toSet());
    });
  }
}
