// One altitude floor (`altitudeFloorProvider`): the site horizon when one is
// set, otherwise the scheduler's minimum altitude, and nothing may quietly
// grow a second one.
//
// The scheduler shipped with 25 deg while SmartNightSettings (the sequence
// builder), the `targets.min_altitude` column and the planner's altitude
// threshold all used 30, so Plan Tonight both admitted and refused the same
// 27 deg target on one screen.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import '../harness/in_memory_database.dart';

void main() {
  test('scheduler and Smart Night agree on the default minimum altitude', () {
    expect(
      SchedulerConfig.defaults.minAltitudeDegrees,
      const SmartNightSettings().minAltitudeDeg,
      reason:
          'these are the same physical quantity - a site floor. Two '
          'defaults means two answers to "can I image this target".',
    );
  });

  test('the provider serves the persisted scheduler minimum', () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        schedulerPersistedConfigProvider.overrideWith(
          (ref) => SchedulerConfig.defaults.copyWith(minAltitudeDegrees: 47),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(schedulerPersistedConfigProvider.future);
    expect(container.read(altitudeFloorProvider).minimumDeg, 47);
    expect(container.read(altitudeFloorProvider).followsHorizon, isFalse);
    expect(container.read(altitudeFloorProvider).atAzimuth(200), 47);
  });

  test('before the durable row loads it reports the engine default', () {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // Never completes: the cold-start read is still in flight.
        schedulerPersistedConfigProvider.overrideWith(
          (ref) => Completer<SchedulerConfig>().future,
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(altitudeFloorProvider).minimumDeg,
      SchedulerConfig.defaults.minAltitudeDegrees,
      reason:
          'the engine runs on defaults until the row lands, so every '
          'other surface must say the same thing rather than pick its own',
    );
  });

  group('a horizon set for the property is the floor', () {
    final trees = SiteHorizonProfile.fromJson(
      '{"N":10,"NE":10,"E":10,"SE":10,"S":10,"SW":35,"W":35,"NW":10}',
    );
    final flat = SiteHorizonProfile.fromJson(
      '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
    );

    test('direction by direction, below and above the minimum', () {
      final floor = AltitudeFloor(horizon: trees, minimumDeg: 25);
      expect(floor.followsHorizon, isTrue);
      expect(floor.atAzimuth(90), 10);
      expect(floor.atAzimuth(250), closeTo(35, 0.01));
      expect(floor.clears(20, 90), isTrue);
      expect(floor.clears(30, 250), isFalse);
      expect(floor.lowestDeg, closeTo(10, 0.01));
    });

    test('a flat horizon leaves the minimum in force', () {
      final floor = AltitudeFloor(horizon: flat, minimumDeg: 25);
      expect(floor.followsHorizon, isFalse);
      expect(floor.atAzimuth(250), 25);
      expect(floor.lowestDeg, 25);
    });

    test('time to set follows the horizon in the setting direction', () {
      // A target setting in the west behind 35 deg trees leaves earlier than
      // it does against a flat 10 deg floor.
      final now = DateTime.utc(2026, 1, 2, 3);
      Duration? left(AltitudeFloor f) => f.timeUntilBelow(
        raDeg: 3.8 * 15,
        decDeg: 24,
        now: now,
        latitudeDeg: 35,
        longitudeDeg: -110,
      );
      final behindTrees = left(AltitudeFloor(horizon: trees, minimumDeg: 0));
      final open = left(AltitudeFloor(horizon: flat, minimumDeg: 10));
      expect(behindTrees, isNotNull);
      expect(open, isNotNull);
      expect(behindTrees!, lessThan(open!));
    });
  });
}
