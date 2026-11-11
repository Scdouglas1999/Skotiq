// Reading the meridian-flip settings and writing them back must leave the
// stored row as it was.
//
// The row is one JSON document. Written whole, a row from before a field
// existed came back from an untouched round trip carrying that field's
// default (`trackingLimitPolicy: flipEarly` on the rig), which pins today's
// default for a setting the operator never chose.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

const _key = 'meridian_flip_settings';

/// The rig's row: written before `trackingLimitPolicy` existed.
const _rowBeforeThePolicyExisted = {
  'standaloneMonitoringEnabled': false,
  'triggerMethod': 'minutesPastMeridian',
  'minutesPastMeridian': 20.0,
  'minutesBeforeLimit': 10.0,
  'hourAngleThreshold': 0.5,
  'trackingLimitWaitMinutes': 0.0,
  'pauseBeforeMeridianMinutes': 20.0,
  'pauseGuidingBeforeFlip': true,
  'recenterAfterFlip': true,
  'refocusAfterFlip': false,
  'settleTimeSeconds': 10.0,
  'resumeGuidingAfterFlip': true,
  'maxRetries': 3,
  'retryDelaysSeconds': [30.0, 60.0, 120.0],
  'failureAction': 'pauseAndAlert',
  'soundAlertOnFlip': false,
  'pushNotificationOnFlip': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late GlobalMeridianFlipSettingsNotifier notifier;

  Future<Map<String, dynamic>?> storedRow() async {
    final raw = await container.read(settingsDaoProvider).getSetting(_key);
    return raw == null || raw.isEmpty
        ? null
        : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> start({Map<String, Object?>? row}) async {
    container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    if (row != null) {
      await container
          .read(settingsDaoProvider)
          .setSetting(_key, jsonEncode(row));
    }
    notifier = container.read(globalMeridianFlipSettingsProvider.notifier);
    await notifier.ensureLoaded();
  }

  test('writing back what was read leaves the row as it was', () async {
    await start(row: _rowBeforeThePolicyExisted);
    final read = container.read(globalMeridianFlipSettingsProvider);
    expect(read.trackingLimitPolicy, TrackingLimitPolicy.flipEarly);

    await notifier.updateSettings(read);

    expect(await storedRow(), _rowBeforeThePolicyExisted);
  });

  test('an edit changes its own field and adds no other', () async {
    await start(row: _rowBeforeThePolicyExisted);
    final read = container.read(globalMeridianFlipSettingsProvider);

    await notifier.updateSettings(read.copyWith(settleTimeSeconds: 25));

    expect(await storedRow(), {
      ..._rowBeforeThePolicyExisted,
      'settleTimeSeconds': 25.0,
    });
  });

  test('a field the operator sets is stored, and stays stored when it is '
      'set back to the default', () async {
    await start(row: _rowBeforeThePolicyExisted);
    final read = container.read(globalMeridianFlipSettingsProvider);

    await notifier.updateSettings(
      read.copyWith(trackingLimitPolicy: TrackingLimitPolicy.values.last),
    );
    expect((await storedRow())!['trackingLimitPolicy'], isNotNull);
    expect(
      container.read(globalMeridianFlipSettingsProvider).trackingLimitPolicy,
      TrackingLimitPolicy.values.last,
    );

    await notifier.updateSettings(read);
    expect((await storedRow())!['trackingLimitPolicy'], 'flipEarly');
  });

  test('with no row yet, only what differs from the defaults is stored, and '
      'it reads back whole', () async {
    await start();
    await notifier.updateSettings(
      const MeridianFlipSettings(refocusAfterFlip: true),
    );
    expect(await storedRow(), {'refocusAfterFlip': true});

    final next = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(container.read(databaseProvider)),
      ],
    );
    addTearDown(next.dispose);
    final reloaded = next.read(globalMeridianFlipSettingsProvider.notifier);
    await reloaded.ensureLoaded();
    expect(
      next.read(globalMeridianFlipSettingsProvider),
      const MeridianFlipSettings(refocusAfterFlip: true),
    );
  });
}
