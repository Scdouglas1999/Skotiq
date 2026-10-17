// Widget tests for the new settings categories
// (Adaptive Exposure, Pre-flight Checks) and the NotificationNode
// transport-override UI.
//
// Why this file is separate from settings_screen_test.dart: the existing
// settings test file is large and tightly scoped to a curated set of
// behaviour assertions. These tests target the *category routing*
// (sidebar entry → correct content widget) and the *new strictness radio* —
// both are additive and don't interact with the pre-existing scenarios.
//
// Post-consolidation note: the sidebar is now grouped + collapsible. Adaptive
// Exposure lives in the (collapsed-by-default) "Imaging" group and Pre-flight
// Checks in "Automation & Safety". These tests expand the owning group header
// first, then tap the section — exercising the real grouped-navigation path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/adaptive_exposure_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/preflight_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';
import 'settings_sidebar_nav.dart';

/// Expands a collapsed sidebar group by its (upper-cased) header. Expanding an
/// earlier group lengthens the list, so a later group's header can start below
/// the fold. See settings_sidebar_nav.dart for why this must not hand-roll
/// scroll-then-tap.
Future<void> _expandGroup(WidgetTester tester, String groupTitle) =>
    expandSettingsGroup(tester, groupTitle);

/// Selects a section row (after its group is expanded).
Future<void> _selectSection(WidgetTester tester, String sectionLabel) =>
    selectSettingsSection(tester, sectionLabel);

/// In-memory stub of [AppSettingsNotifier] — same pattern as the main
/// settings_screen_test. Tests inject an initial state and exercise
/// real setter methods (which still write to the in-memory DAO).
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() {
    FlutterError.onError = defaultOnError;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'sidebar_lists_adaptive_exposure_and_preflight_checks: the two new '
      'new categories appear under their groups in the sidebar',
      (tester) async {
    _swallowKnownOverflows();
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

    // Both groups start collapsed; expand them and reveal their sections (the
    // grouped ListView builds rows lazily, so scroll the entry into view).
    await _expandGroup(tester, 'Imaging');
    await revealInSettingsSidebar(tester, find.text('Adaptive exposure'));
    expect(find.text('Adaptive exposure'), findsOneWidget,
        reason: 'The "Adaptive exposure" sidebar entry must exist under the '
            'Imaging group.');

    await _expandGroup(tester, 'Automation & Safety');
    await revealInSettingsSidebar(tester, find.text('Pre-flight checks'));
    expect(find.text('Pre-flight checks'), findsOneWidget,
        reason: 'The "Pre-flight checks" sidebar entry must exist under the '
            'Automation & Safety group.');
  });

  testWidgets(
      'tapping_adaptive_exposure_renders_widget: the sidebar entry maps to '
      'AdaptiveExposureSettings in the content pane', (tester) async {
    _swallowKnownOverflows();
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

    await _expandGroup(tester, 'Imaging');
    await _selectSection(tester, 'Adaptive exposure');

    expect(find.byType(AdaptiveExposureSettings), findsOneWidget,
        reason: 'Tapping Adaptive Exposure must swap the content pane to '
            'AdaptiveExposureSettings — otherwise the case-index dispatch '
            'in _buildContent has drifted.');
  });

  testWidgets(
      'tapping_preflight_checks_renders_widget_with_strictness_radio: the '
      'sidebar entry maps to PreflightSettings and the radio group exists',
      (tester) async {
    _swallowKnownOverflows();
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

    await _expandGroup(tester, 'Automation & Safety');
    await _selectSection(tester, 'Pre-flight checks');

    expect(find.byType(PreflightSettings), findsOneWidget,
        reason: 'Tapping Pre-flight Checks must render PreflightSettings.');
    // The radio group has three Radio<PreflightStrictness> widgets.
    expect(find.byType(Radio<PreflightStrictness>), findsNWidgets(3),
        reason: 'PreflightSettings must surface three strictness options '
            '(lax / normal / strict).');
  });

  testWidgets(
      'changing_preflight_strictness_updates_settings: tapping the Strict '
      'option moves AppSettingsState.preflightStrictness to strict',
      (tester) async {
    _swallowKnownOverflows();
    const initial = AppSettingsState(); // default = normal
    expect(initial.preflightStrictness, PreflightStrictness.normal,
        reason: 'Sanity: default is normal.');

    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(initial),
        ),
      ],
    );

    await _expandGroup(tester, 'Automation & Safety');
    await _selectSection(tester, 'Pre-flight checks');

    // The Strict option carries a ValueKey we can target deterministically.
    final strictRow = find.byKey(const ValueKey('preflightStrictness_strict'));
    expect(strictRow, findsOneWidget,
        reason: 'The Strict option row must carry its ValueKey.');
    await tester.tap(strictRow);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final state = handle.container.read(appSettingsProvider).value;
    expect(state, isNotNull);
    expect(state!.preflightStrictness, PreflightStrictness.strict,
        reason: 'Tapping the Strict option must call '
            'setPreflightStrictness(PreflightStrictness.strict).');
  });
}
