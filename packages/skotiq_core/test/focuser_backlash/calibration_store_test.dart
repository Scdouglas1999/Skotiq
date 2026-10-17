import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/focuser_backlash_calibration.dart';

import 'fixtures.dart';

void main() {
  late SkotiqDatabase database;
  late SettingsDao dao;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = SettingsDao(database);
  });

  tearDown(() => database.close());

  test('a saved measurement round-trips every field', () async {
    await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());

    final read = await dao.getFocuserBacklashCalibration('zwo-eaf-1');

    expect(read, isNotNull);
    expect(read!.steps, 105);
    expect(read.measurable, isTrue);
    expect(read.resolutionLimitSteps, 15.0);
    expect(read.measuredAtPosition, 6620);
    expect(read.temperatureCelsius, 14.5);
    expect(read.measuredAt, DateTime.utc(2026, 9, 14, 23, 11, 4));
    expect(read.confidence, FocuserBacklashConfidence.high);
    expect(read.confidenceReason, 'Both directions fitted well.');
    expect(read.appVersion, '7.0.0+27');
    expect(read, recordFor());
  });

  test('the calibration a run produced saves as its own record', () async {
    final calibration = FocuserBacklashResult.tryParse(
      measuredOutcomeJson(),
    )!.calibration!;

    await dao.saveFocuserBacklashCalibration(
      calibration.focuserDeviceId,
      calibration.toRecord(),
    );

    final read = await dao.getFocuserBacklashCalibration('zwo-eaf-1');
    expect(read!.steps, 105);
    expect(read.measuredAtPosition, 6620);
    expect(read.temperatureCelsius, 14.5);
  });

  test('a record is invisible to a different focuser', () async {
    // The whole reason the store is keyed by device id: a dead band belongs to
    // one drive train, and the existing global af_backlash_in silently carries
    // the last focuser's figure onto the next one.
    await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());

    expect(
      await dao.getFocuserBacklashCalibration('pegasus-focuscube-2'),
      isNull,
    );
    expect((await dao.getFocuserBacklashCalibration('zwo-eaf-1'))!.steps, 105);
  });

  test('two focusers keep their own figures at their own positions', () async {
    // Backlash varies along the travel as well as between focusers: 105 steps
    // near 6600 and 83 near 2500 were both measured on the owner's EAF.
    await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
    await dao.saveFocuserBacklashCalibration(
      'pegasus-focuscube-2',
      recordFor(steps: 83, position: 2500, temperature: 9.0),
    );

    final all = await dao.getFocuserBacklashCalibrations();
    expect(all, hasLength(2));
    expect(all['zwo-eaf-1']!.steps, 105);
    expect(all['zwo-eaf-1']!.measuredAtPosition, 6620);
    expect(all['pegasus-focuscube-2']!.steps, 83);
    expect(all['pegasus-focuscube-2']!.measuredAtPosition, 2500);
  });

  test('clearing one focuser leaves the others alone', () async {
    await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
    await dao.saveFocuserBacklashCalibration(
      'pegasus-focuscube-2',
      recordFor(steps: 83, position: 2500),
    );

    await dao.clearFocuserBacklashCalibration('zwo-eaf-1');

    expect(await dao.getFocuserBacklashCalibration('zwo-eaf-1'), isNull);
    expect(
      (await dao.getFocuserBacklashCalibration('pegasus-focuscube-2'))!.steps,
      83,
    );
  });

  test('a no-measurable-backlash result is stored, not discarded', () async {
    await dao.saveFocuserBacklashCalibration(
      'zwo-eaf-1',
      recordFor(steps: 0, measurable: false),
    );

    final read = await dao.getFocuserBacklashCalibration('zwo-eaf-1');
    expect(read, isNotNull);
    expect(read!.steps, 0);
    expect(read.measurable, isFalse);
  });

  group('the LRU cap', () {
    test('keeps the eight most recent focusers by measurement date', () async {
      for (var i = 0; i < 10; i++) {
        await dao.saveFocuserBacklashCalibration(
          'focuser-$i',
          recordFor(
            steps: 100 + i,
            measuredAt: DateTime.utc(2026, 9, 1).add(Duration(days: i)),
          ),
        );
      }

      final all = await dao.getFocuserBacklashCalibrations();
      expect(all, hasLength(8));
      // The two oldest fell off; nothing newer was evicted.
      expect(all.containsKey('focuser-0'), isFalse);
      expect(all.containsKey('focuser-1'), isFalse);
      expect(all['focuser-9']!.steps, 109);
      expect(all['focuser-2']!.steps, 102);
    });
  });

  group('values that cannot be trusted', () {
    test('a corrupt stored blob reads as nothing measured', () async {
      await dao.setSetting(
        'focuser_backlash_calibrations.v1',
        'not json at all',
      );

      expect(await dao.getFocuserBacklashCalibrations(), isEmpty);
      expect(await dao.getFocuserBacklashCalibration('zwo-eaf-1'), isNull);
    });

    test('one unreadable entry does not hide the readable ones', () async {
      await dao.setSetting(
        'focuser_backlash_calibrations.v1',
        jsonEncode({
          'zwo-eaf-1': recordFor().toJson(),
          'broken-focuser': {'s': 'lots'},
        }),
      );

      final all = await dao.getFocuserBacklashCalibrations();
      expect(all.keys, ['zwo-eaf-1']);
    });

    test('a negative figure is refused rather than applied', () async {
      final negative = recordFor(steps: -40);
      expect(negative.isUsable, isFalse);

      await dao.saveFocuserBacklashCalibration('zwo-eaf-1', negative);
      expect(await dao.getFocuserBacklashCalibration('zwo-eaf-1'), isNull);
    });

    test('a non-finite resolution limit is refused', () {
      expect(recordFor(resolutionLimit: double.nan).isUsable, isFalse);
      expect(recordFor(resolutionLimit: double.infinity).isUsable, isFalse);
    });

    test('measurable and the figure must agree', () {
      // "Measurable, 0 steps" and "not measurable, 105 steps" are both
      // self-contradictory, and a contradiction must not move a drawtube.
      expect(recordFor(steps: 0).isUsable, isFalse);
      expect(recordFor(steps: 105, measurable: false).isUsable, isFalse);
      expect(recordFor(steps: 0, measurable: false).isUsable, isTrue);
    });

    test('an unusable record never overwrites a good one', () async {
      await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
      await dao.saveFocuserBacklashCalibration(
        'zwo-eaf-1',
        recordFor(steps: -5),
      );

      expect(
        (await dao.getFocuserBacklashCalibration('zwo-eaf-1'))!.steps,
        105,
      );
    });

    test('an empty focuser id is not a key', () async {
      await dao.saveFocuserBacklashCalibration('', recordFor());
      expect(await dao.getFocuserBacklashCalibrations(), isEmpty);
      expect(await dao.getFocuserBacklashCalibration(''), isNull);
    });
  });

  test('re-saving an unchanged record writes nothing', () async {
    await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());
    final before = await dao.getSetting('focuser_backlash_calibrations.v1');

    await dao.saveFocuserBacklashCalibration('zwo-eaf-1', recordFor());

    expect(await dao.getSetting('focuser_backlash_calibrations.v1'), before);
  });
}
