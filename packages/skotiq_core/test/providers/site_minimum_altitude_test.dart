// One site minimum altitude, and nothing may quietly grow a second one.
//
// The scheduler shipped with 25 deg while SmartNightSettings (the sequence
// builder), the `targets.min_altitude` column and the planner's altitude
// threshold all used 30, so Plan Tonight both admitted and refused the same
// 27 deg target on one screen.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
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
    expect(container.read(siteMinimumAltitudeDegProvider), 47);
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
      container.read(siteMinimumAltitudeDegProvider),
      SchedulerConfig.defaults.minAltitudeDegrees,
      reason:
          'the engine runs on defaults until the row lands, so every '
          'other surface must say the same thing rather than pick its own',
    );
  });
}
