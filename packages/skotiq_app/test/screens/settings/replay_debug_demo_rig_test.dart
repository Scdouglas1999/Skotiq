// The demo rig switch sits at the bottom of Replay & debug on a phone, and
// nowhere on a computer, which has the real simulators of its own rig.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/replay_debug_settings.dart'
    as replay_ui;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(WidgetTester tester) => pumpAppScreen(
      tester,
      const replay_ui.ReplayDebugSettings(),
      size: const Size(400, 1600),
      extraOverrides: [
        replayDebugEnabledProvider.overrideWith((ref) async => true),
        replayDebugRetentionDaysProvider.overrideWith((ref) async => 90),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => DeviceTraits.debugOverride = null);

  testWidgets('a phone has the switch, and it turns the setting on', (
    tester,
  ) async {
    DeviceTraits.debugOverride = DeviceTraits.phone;
    final handle = await _pump(tester);

    expect(find.text('TESTING'), findsOneWidget);
    expect(find.text('Demo rig (testing)'), findsOneWidget);
    expect(
      find.textContaining('Simulates equipment on this phone when it is not '
          'linked to an imaging computer'),
      findsOneWidget,
    );
    final row = find.byKey(const ValueKey('settings.demoRig'));
    final toggle = find.descendant(
      of: row,
      matching: find.byType(SettingsSwitch),
    );
    expect(tester.widget<SettingsSwitch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final settings = await handle.container.read(appSettingsProvider.future);
    expect(settings.demoRig, isTrue);
    expect(tester.widget<SettingsSwitch>(toggle).value, isTrue);
  });

  testWidgets('a computer does not show it', (tester) async {
    DeviceTraits.debugOverride = DeviceTraits.desktop;
    await _pump(tester);
    expect(find.text('Demo rig (testing)'), findsNothing);
  });
}
