import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A settings toggle must announce WHICH setting it is.
///
/// Two separate defects were measured on the running app, in sequence:
///   1. The switch exposed no accessibility semantics at all — Settings >
///      General reported ZERO checkable nodes and only five focusable ones, so
///      the 664 setting rows were unreachable by keyboard and unreadable by a
///      screen reader. Fixed in `SkotiqSwitch`.
///   2. With that fixed, the same screen exposed three toggle buttons reading
///      "off/ON/ON" with EMPTY NAMES. Assistive technology could say something
///      was on without being able to say what. The row owns the label, the
///      switch owns the state, and nothing bound them together.
///
/// This pins the second: the row must present as ONE node carrying both.
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
          icon: LucideIcons.power,
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
          icon: LucideIcons.power,
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
          icon: LucideIcons.palette,
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
