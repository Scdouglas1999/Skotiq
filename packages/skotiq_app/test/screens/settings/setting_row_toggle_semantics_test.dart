import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// `SettingRow` wraps every row in `MergeSemantics` to bind the label to the
/// switch. This pins that the MERGED node carries both the label and the
/// toggled state, at the widget layer where it is cheap to see (an AT-SPI
/// reading of the same row can drop the state).
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
          title: 'Start minimized',
          subtitle: 'Launch app minimized to system tray',
          trailing: SkotiqSwitch(value: true, onChanged: (_) {}),
        ),
      );
}
