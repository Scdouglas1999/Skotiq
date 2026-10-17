import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/adaptive_exposure_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pumpSettings(WidgetTester tester) async {
  final database = mockDatabase();
  await database.settingsDao.setSettings({
    'adaptive_exposure_enabled': 'true',
    'adaptive_exposure_min_secs': '5',
    'adaptive_exposure_max_secs': '600',
  });
  addTearDown(database.close);
  return pumpAppScreen(
    tester,
    const SingleChildScrollView(child: AdaptiveExposureSettings()),
    size: const Size(900, 1000),
    database: database,
    extraOverrides: [
      activeEquipmentProfileProvider.overrideWithValue(
        const EquipmentProfileModel(
          id: 1,
          name: 'Test Rig',
          filterNames: ['L', 'R'],
          isActive: true,
        ),
      ),
    ],
    settle: false,
  );
}

Future<void> _pumpWrites(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('inverted global bounds show an error and are not persisted',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final minField = find.byKey(
      const ValueKey('adaptive-global-min-secs'),
    );
    await tester.enterText(minField, '700');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(
      find.text('Minimum exposure cannot exceed maximum exposure.'),
      findsOneWidget,
    );
    expect(
      handle.container.read(appSettingsProvider).value!.adaptiveExposureMinSecs,
      5,
    );
  });

  testWidgets('first filter edit preserves the implicit enabled state of peers',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();

    final checkboxes = find.byType(SkotiqCheckbox);
    expect(checkboxes, findsNWidgets(2));
    await tester.ensureVisible(checkboxes.first);
    await tester.tap(checkboxes.first);
    await _pumpWrites(tester);

    expect(
      handle.container
          .read(appSettingsProvider)
          .value!
          .adaptiveExposurePerFilterEnabled,
      const {'L': false, 'R': true},
    );
  });
}
