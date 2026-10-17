import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/autofocus_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _ConnectedFilterWheelNotifier extends FilterWheelStateNotifier {
  _ConnectedFilterWheelNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'filter-wheel-1',
      deviceName: 'Test Wheel',
      currentPosition: 0,
      filterNames: ['L', 'R'],
    );
  }
}

Future<HarnessHandle> _pumpSettings(WidgetTester tester) async {
  final database = mockDatabase();
  await database.settingsDao.setSetting('af_filter_settings', '{}');
  addTearDown(database.close);
  return pumpAppScreen(
    tester,
    const AutofocusSettingsPage(),
    size: const Size(1280, 1000),
    database: database,
    settle: false,
    extraOverrides: [
      filterWheelStateProvider.overrideWith(
        _ConnectedFilterWheelNotifier.new,
      ),
    ],
  );
}

Future<void> _pumpWrites(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('per-filter exposure commits on submit rather than keystrokes',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(const ValueKey('af-filter-L-exposure'));
    await tester.ensureVisible(field);

    await tester.enterText(field, '2');
    await tester.pump();
    var encoded =
        handle.container.read(appSettingsProvider).value!.afFilterSettingsJson;
    expect(AutofocusSettings.parseFilterSettingsJson(encoded), isEmpty);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);
    encoded =
        handle.container.read(appSettingsProvider).value!.afFilterSettingsJson;
    expect(
      AutofocusSettings.parseFilterSettingsJson(encoded)['L']!.afExposureTime,
      2,
    );
  });

  testWidgets('per-filter exposure clamps persisted and visible values',
      (tester) async {
    final handle = await _pumpSettings(tester);
    await tester.pump();
    final field = find.byKey(const ValueKey('af-filter-L-exposure'));
    await tester.ensureVisible(field);

    await tester.enterText(field, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpWrites(tester);

    final encoded =
        handle.container.read(appSettingsProvider).value!.afFilterSettingsJson;
    expect(
      AutofocusSettings.parseFilterSettingsJson(encoded)['L']!.afExposureTime,
      0.1,
    );
    expect(tester.widget<TextField>(field).controller!.text, '0.1');
  });
}
