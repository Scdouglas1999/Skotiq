import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Live GUI drive 2026-08-10: Settings → General exposed
/// `toggle button: Start minimized` with NO on/off state, while the same
/// switch component on the Imaging screen published `[off]`. `SettingRow`
/// wraps every row in `MergeSemantics`, added earlier to bind the label to a
/// switch that was "correctly-toggled but ANONYMOUS".
///
/// This test asked the decisive question the accessibility tree could not: does
/// the MERGED node carry both the label and the toggled state?
///
/// **It does.** The merged node comes out as
/// `flags: [hasEnabledState, isEnabled, hasToggledState, isToggled],
/// label: "Start minimized\nLaunch app minimized to system tray"` — so the
/// widget layer is right, the merge did NOT trade the state away, and the loss
/// I measured is in the AT-SPI bridge or in how the audit harness reads it.
///
/// Kept as a regression guard: if a future change to `SettingRow` or
/// `SkotiqSwitch` drops either half, this fails at the widget layer where
/// it is cheap to see.
void main() {
  testWidgets('a settings row publishes its label AND its switch state',
      (tester) async {
    await pumpAppScreen(
      tester,
      const _RowUnderTest(),
    );
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byType(SettingRow)),
      matchesSemantics(
        label: 'Start minimized\nLaunch app minimized to system tray',
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
  });
}

class _RowUnderTest extends StatelessWidget {
  const _RowUnderTest();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SettingRow(
          icon: Icons.power_settings_new,
          title: 'Start minimized',
          subtitle: 'Launch app minimized to system tray',
          trailing: SkotiqSwitch(value: true, onChanged: (_) {}),
        ),
      );
}
