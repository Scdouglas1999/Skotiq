import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';
import 'package:skotiq_app/screens/settings/widgets/end_of_night_calibration_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

/// A rig with tonight's lights, a camera and a wheel without a dark slot, so
/// the step stops to ask for a cap.
class _CapRig extends Fake implements EonRig {
  final notifications = <String>[];

  @override
  DateTime now() => DateTime(2026, 10, 22, 6);

  @override
  Future<List<db.CapturedImage>> lightFramesSince(DateTime since) async => [
        db.CapturedImage(
          id: 1,
          filePath: '/n/L_1.fits',
          fileName: 'L_1.fits',
          fileFormat: 'fits',
          frameType: 'light',
          exposureDuration: 90,
          gain: 76,
          offset: 15,
          binX: 1,
          binY: 1,
          sensorTemp: -10,
          isPlateSolved: false,
          capturedAt: since,
          createdAt: since,
          isAccepted: true,
        ),
      ];

  @override
  Future<EonCameraInfo?> camera() async =>
      const EonCameraInfo(canCool: true, coolerOn: true, targetTempC: -10);

  @override
  Future<List<String>?> filterNames() async => const ['L', 'R', 'G', 'B'];

  @override
  Future<String?> stopGuiding() async => null;

  @override
  Future<String> secureMount(EonMountAction action) async => 'Mount sent home';

  @override
  Future<void> notify(String title, String message,
          {bool problem = false}) async =>
      notifications.add(title);

  @override
  Future<void> saveReport(Map<String, Object?> report) async {}
}

void main() {
  testWidgets('the section lives in Automation & Safety', (
    tester,
  ) async {
    expect(groupTitleForKey('end-of-night-calibration'), 'Automation & Safety');
    expect(
      resolveSectionKey('end-of-night-calibration'),
      'end-of-night-calibration',
    );
  });

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    testWidgets('the switch writes the setting the step reads ($size)', (
      tester,
    ) async {
      final database = mockDatabase();
      addTearDown(database.close);
      await pumpAppScreen(
        tester,
        const SingleChildScrollView(child: EndOfNightCalibrationSettings()),
        database: database,
        size: size,
      );

      expect(
          find.text('Take darks and bias when imaging ends'), findsOneWidget);
      expect(
          find.text('Without a dark slot in the filter wheel'), findsOneWidget);
      expect(find.text('Take darks and bias now'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final toggle = find.descendant(
        of: find.ancestor(
          of: find.text('Take darks and bias when imaging ends'),
          matching: find.byType(SettingRow),
        ),
        matching: find.byType(SettingsSwitch),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final stored = await EonSettings.load(SettingsDao(database));
      expect(stored.enabled, isTrue);
    });
  }

  testWidgets('waiting for a cap offers the confirmation', (tester) async {
    final rig = _CapRig();
    final database = mockDatabase();
    addTearDown(database.close);
    late EndOfNightCalibrationService service;
    await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: EndOfNightCalibrationSettings()),
      database: database,
      extraOverrides: [
        endOfNightCalibrationProvider.overrideWith((ref) {
          return service = EndOfNightCalibrationService(
            rig,
            () async => const EonSettings(enabled: true),
          );
        }),
      ],
    );

    final run = service.run(reason: 'manual');
    await tester.pump();
    await tester.pump();
    expect(find.text('Calibration: Waiting for cap'), findsOneWidget);
    expect(find.text('The telescope is capped'), findsOneWidget);
    expect(rig.notifications, contains('Cap the telescope for darks'));

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    final report = await run;
    expect(report.phase, EonPhase.cancelled);
    expect(find.text('Calibration: Stopped'), findsOneWidget);
  });
}
