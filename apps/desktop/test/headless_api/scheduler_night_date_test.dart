// The scheduler's sky routes answer for the night under way: asked at 01:30
// at the site, a target's rise, transit and set are the ones of the night that
// began the evening before, not of the next night.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_desktop/headless_api/handlers/scheduler_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

const _latitude = 40.7;
const _longitude = -74.0;

void main() {
  late SkotiqDatabase database;
  late ProviderContainer container;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    await database.settingsDao.write(AppSettingDefs.latitude, _latitude);
    await database.settingsDao.write(AppSettingDefs.longitude, _longitude);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<Map<String, Object?>> ask(String route, DateTime now) async {
    // The host's clock reads local time, as DateTime.now() does.
    final handlers = SchedulerHandlers(container, now: () => now.toLocal());
    final request = Request(
      'GET',
      Uri.parse('http://localhost/api/scheduler/$route?ra=5.59&dec=-5.39'),
    );
    final response = await translateHandlerErrors(
      route == 'transit-time'
          ? handlers.handleCalculateTransitTime(request)
          : handlers.handleCalculateRiseSet(request),
    );
    return jsonDecode(await response.readAsString()) as Map<String, Object?>;
  }

  // The night of 2026-11-21 at the site: site solar noon to site solar noon.
  final nightStart = AstronomyCalculations.nightStartOf(
    DateTime.utc(2026, 11, 21),
    longitudeDeg: _longitude,
  );
  final nightEnd = nightStart.add(const Duration(days: 1));

  void expectInTheNight(Object? epochMs, String key, DateTime now) {
    expect(epochMs, isA<int>(), reason: key);
    final at = DateTime.fromMillisecondsSinceEpoch(
      epochMs! as int,
      isUtc: true,
    );
    expect(
      !at.isBefore(nightStart) && at.isBefore(nightEnd),
      isTrue,
      reason:
          '$key $at asked at $now is not in the night of 2026-11-21 '
          '($nightStart .. $nightEnd)',
    );
  }

  for (final now in [
    DateTime.utc(2026, 11, 22, 2), // 21:00 at the site
    DateTime.utc(2026, 11, 22, 6, 30), // 01:30 at the site
    DateTime.utc(2026, 11, 22, 10), // 05:00 at the site
  ]) {
    test('transit-time asked at $now names the night under way', () async {
      final body = await ask('transit-time', now);
      expectInTheNight(body['transitTimeEpoch'], 'transitTimeEpoch', now);
    });

    test('rise-set asked at $now names the night under way', () async {
      final body = await ask('rise-set', now);
      for (final key in ['riseTimeEpoch', 'transitTimeEpoch', 'setTimeEpoch']) {
        expectInTheNight(body[key], key, now);
      }
    });
  }
}
