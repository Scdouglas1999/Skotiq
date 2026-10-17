import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/auto_integration_service.dart';
import 'package:skotiq_app/screens/settings/widgets/image_grading_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pumpSettings(
  WidgetTester tester, {
  Map<String, String> extraSettings = const {},
}) async {
  final database = mockDatabase();
  await database.settingsDao.setSettings({
    'image_grading_enabled': 'true',
    'image_grading_hfr_threshold_px': '3.5',
    'image_grading_max_consecutive_rejects': '3',
    kAutoIntegrateSettingKey: 'false',
    ...extraSettings,
  });
  addTearDown(database.close);
  return pumpAppScreen(
    tester,
    const ImageGradingSettings(),
    size: const Size(900, 1000),
    database: database,
    settle: false,
  );
}

/// True when any rendered Text contains [fragment]. Threshold warnings are
/// appended to the row subtitle, so this asserts what the operator actually
/// reads rather than an internal flag.
bool _rendersText(WidgetTester tester, String fragment) => tester
    .widgetList<Text>(find.byType(Text))
    .any((t) => (t.data ?? '').contains(fragment));

Future<void> _pumpWrites(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('thresholds commit on submit and clamp the visible value',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(
      const ValueKey('image-grading-hfr-threshold'),
    );
    await tester.ensureVisible(field);

    await tester.enterText(field, '999');
    await tester.pump();
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .imageGradingHfrThresholdPx,
      3.5,
    );

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);
    // 20 px is StarDetectionConfig.hfr_radius — the window the half-flux radius
    // is measured in. A higher ceiling lets an operator save a threshold no
    // frame can ever exceed: a silently dead gate.
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .imageGradingHfrThresholdPx,
      20,
    );
    expect(tester.widget<TextField>(field).controller!.text, '20.00');
  });

  testWidgets('required blank input restores the committed value',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(const ValueKey('image-grading-max-rejects'));
    await tester.ensureVisible(field);

    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(tester.widget<TextField>(field).controller!.text, '3');
    expect(find.text('A value is required.'), findsOneWidget);
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .imageGradingMaxConsecutiveRejects,
      3,
    );
  });

  testWidgets('clearing an optional threshold disables only that check',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(
      const ValueKey('image-grading-star-count-minimum'),
    );
    await tester.ensureVisible(field);

    await tester.enterText(field, '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);

    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .imageGradingStarCountMin,
      isNull,
    );
  });

  testWidgets('eccentricity clamps to a value the detector can exceed',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(
      const ValueKey('image-grading-eccentricity-threshold'),
    );
    await tester.ensureVisible(field);

    await tester.enterText(field, '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);

    // DETECTION_MAX_ECCENTRICITY = 0.95: the detector filters anything more
    // elongated out as a streak, so the frame median never exceeds 0.95 and
    // grading rejects on `ecc > threshold` — a threshold *at* 0.95 is as dead
    // as one above it, and a dead gate looks armed on screen.
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .imageGradingEccentricityThreshold,
      0.94,
    );
    expect(tester.widget<TextField>(field).controller!.text, '0.94');
  });

  testWidgets('HFR clamps up to the floor the detector can report',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(const ValueKey('image-grading-hfr-threshold'));
    await tester.ensureVisible(field);

    await tester.enterText(field, '0.05');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);

    // StarDetectionConfig.min_hfr = 1.0: every detected star is at least that
    // wide, so "reject if HFR > 0.05" would reject every frame with stars.
    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .imageGradingHfrThresholdPx,
      1.0,
    );
  });

  testWidgets('a stored threshold past the measurable range says it is dead',
      (tester) async {
    await _pumpSettings(
      tester,
      // Values like these were reachable before the inputs were bounded, and
      // they still load unclamped.
      extraSettings: {
        'image_grading_hfr_threshold_px': '50.0',
        'image_grading_eccentricity_threshold': '1.0',
      },
    );
    await tester.pump();

    expect(_rendersText(tester, 'at 50.00 px this check never fires'), isTrue);
    expect(_rendersText(tester, 'at 1.00 this check never fires'), isTrue);
  });

  testWidgets('an eccentricity threshold exactly at the ceiling is dead too',
      (tester) async {
    // Grading rejects on `ecc > threshold` and the median can only reach 0.95,
    // so a field max of 0.95 never fires either.
    await _pumpSettings(
      tester,
      extraSettings: {'image_grading_eccentricity_threshold': '0.95'},
    );
    await tester.pump();

    expect(_rendersText(tester, 'at 0.95 this check never fires'), isTrue);
  });

  testWidgets('a stored threshold below the measurable range says so too',
      (tester) async {
    await _pumpSettings(
      tester,
      extraSettings: {'image_grading_hfr_threshold_px': '0.1'},
    );
    await tester.pump();

    expect(_rendersText(tester, 'at 0.10 px this rejects every frame'), isTrue);
  });

  testWidgets('a usable threshold carries no warning', (tester) async {
    await _pumpSettings(tester);
    await tester.pump();

    expect(_rendersText(tester, 'Heads up:'), isFalse);
  });

  testWidgets('auto-integration toggle persists immediately', (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final toggle = find.byKey(const ValueKey('auto-integrate-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _pumpWrites(tester);

    expect(
      await handle.database.settingsDao.getSetting(kAutoIntegrateSettingKey),
      'true',
    );
  });
}
