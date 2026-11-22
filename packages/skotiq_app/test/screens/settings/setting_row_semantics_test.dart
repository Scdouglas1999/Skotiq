import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A settings toggle must announce WHICH setting it is.
///
/// The row owns the label and the switch owns the state; without a binding a
/// screen reader can say something is on without being able to say what. The
/// row must present as ONE node carrying both.
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets(
      'a settings row announces its title together with its toggle '
      'state', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      wrap(
        SettingRow(
          title: 'Start minimized',
          subtitle: 'Launch app minimized to system tray',
          trailing: SkotiqSwitch(value: true, onChanged: (_) {}),
        ),
      ),
    );

    // One merged node, not a label and an anonymous toggle sitting apart.
    // Assert the properties that form the accessibility contract while leaving
    // unrelated semantics unspecified.
    expect(
      tester.getSemantics(find.byType(SettingRow)),
      isSemantics(
        // Title AND subtitle: the merge carries the setting's explanation into
        // the announcement too, which is the behaviour worth keeping.
        label: 'Start minimized\nLaunch app minimized to system tray',
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
      reason: 'the control must carry the name of the setting it changes AND '
          'the state it is in',
    );

    handle.dispose();
  });

  testWidgets('the merged node follows the switch value', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      wrap(
        SettingRow(
          title: 'Confirm before closing',
          trailing: SkotiqSwitch(value: false, onChanged: (_) {}),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(SettingRow)),
      isSemantics(
        label: 'Confirm before closing',
        hasToggledState: true,
        isToggled: false,
      ),
    );

    handle.dispose();
  });

  /// The row that hid a missing role for the whole app.
  ///
  /// `SkotiqDropdown` published no button role of its own on the closed
  /// control whenever it also carried a hint, and every settings dropdown got
  /// away with it because this row merges its title and its control into one
  /// node that Material happened to annotate. The component now states the
  /// role itself; a row hosting one must still announce ONE control, with the
  /// setting's name and its current value, and not the value twice.
  testWidgets('a settings row announces its dropdown once, with its value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      wrap(
        SettingRow(
          title: 'Theme',
          trailing: SettingsDropdown(
            value: 'Dark',
            items: const ['Light', 'Dark', 'Red night'],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(SettingRow)),
      isSemantics(
        label: 'Theme\nDark',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
      reason: 'the row must name the setting, its value and the fact that the '
          'value can be changed',
    );

    handle.dispose();
  });
}
