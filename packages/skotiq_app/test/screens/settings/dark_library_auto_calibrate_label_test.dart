// The Dark Library "auto" switch is `calibration.auto_calibrate` - the same
// boolean the Calibration page owns, and the gate on the whole calibrateFile()
// call (dark AND flat AND bias). A label like 'Auto dark subtraction'
// understates that scope: turning it off silently disables flat and bias
// correction too. These tests pin the label to the behaviour.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/dark_library_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(WidgetTester tester) async {
  final database = mockDatabase();
  await database.settingsDao.setSettings({
    'calibration.auto_calibrate': 'true',
  });
  addTearDown(database.close);
  return pumpAppScreen(
    tester,
    const SingleChildScrollView(child: DarkLibrarySettings()),
    size: const Size(1000, 1400),
    database: database,
    settle: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the row is labelled for everything the switch actually gates',
      (tester) async {
    await _pump(tester);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(
      find.text('Auto-calibrate light frames'),
      findsOneWidget,
      reason: 'must match the Calibration page, which owns the same boolean',
    );
    expect(find.text('Auto dark subtraction'), findsNothing);
    expect(
      find.textContaining('Apply dark, flat, and bias correction'),
      findsOneWidget,
    );
    expect(
      find.textContaining('subtract matching darks from light frames'),
      findsNothing,
      reason: 'the narrow darks-only claim is what made the control lie',
    );
  });

  testWidgets('toggling it writes the shared master calibration flag',
      (tester) async {
    final handle = await _pump(tester);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(
      handle.container.read(calibrationSettingsProvider).autoCalibrate,
      isTrue,
    );

    final row = find.ancestor(
      of: find.text('Auto-calibrate light frames'),
      matching: find.byType(SettingRow),
    );
    final switchFinder = find.descendant(
      of: row,
      matching: find.byType(SettingsSwitch),
    );
    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    // Proves the label is not decorative: this one tap is what also turns off
    // flat and bias correction (imaging_service gates calibrateFile on it).
    expect(
      handle.container.read(calibrationSettingsProvider).autoCalibrate,
      isFalse,
    );
    expect(
      await handle.database.settingsDao
          .getSetting('calibration.auto_calibrate'),
      'false',
    );
  });
}
