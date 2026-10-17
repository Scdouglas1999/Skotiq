import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/adaptive_conditions_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';
import 'settings_sidebar_nav.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

/// The sidebar is grouped + collapsible; Adaptive Conditions lives in the
/// (collapsed-by-default) "Automation & Safety" group. Expand the group, then
/// select the section. See settings_sidebar_nav.dart for why this must not
/// hand-roll scroll-then-tap.
Future<void> _openAdaptiveConditions(WidgetTester tester) async {
  await expandSettingsGroup(tester, 'Automation & Safety');
  await selectSettingsSection(tester, 'Adaptive conditions');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'tapping_adaptive_conditions_renders_widget: the sidebar entry maps '
      'to AdaptiveConditionsSettings', (tester) async {
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(const AppSettingsState()),
        ),
      ],
    );

    await _openAdaptiveConditions(tester);

    expect(find.byType(AdaptiveConditionsSettings), findsOneWidget);
  });

  testWidgets(
      'adaptive_conditions_controls_update_existing_settings: changing '
      'defaults persists through AppSettingsNotifier setters', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(const AppSettingsState()),
        ),
      ],
    );

    await _openAdaptiveConditions(tester);

    expect(find.text('Enabled for new schedulers'), findsOneWidget);
    expect(find.text('Score floor'), findsOneWidget);
    expect(find.text('Swap hysteresis'), findsOneWidget);
    expect(find.text('Transparency weight'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('adaptiveSwapEnabledToggle')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('adaptiveSwapThresholdInput')),
      '62',
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('adaptiveSwapTransparencyWeightInput')),
      '0.55',
    );
    // SettingsNumberInput deliberately commits on Enter or blur, rather than
    // writing once per keystroke. Submit the final field just as a keyboard
    // user would; the preceding threshold edit committed when focus moved.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final state = handle.container.read(appSettingsProvider).value;
    expect(state, isNotNull);
    expect(state!.adaptiveSwapEnabledByDefault, isTrue);
    expect(state.adaptiveSwapDefaultThreshold, 62.0);
    expect(state.conditionsScoreWeights['transparency'], 0.55);
  });
}
