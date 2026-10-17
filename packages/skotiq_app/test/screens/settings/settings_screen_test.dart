// Widget tests for SettingsScreen.
//
// The Settings screen is a GROUPED, collapsible, searchable sidebar (desktop)
// / list (mobile) driven by the declarative catalog in settings_catalog.dart.
// Navigation deep-links by STABLE STRING KEY (the real contract); the integer
// `kSettingsSectionIndex` is a derived compatibility shim only.
//
// These tests cover:
//   * the default pane (first catalog section) renders,
//   * the grouped sidebar shows all 7 group headers,
//   * expanding a group + selecting a section swaps the detail pane,
//   * form validation / persistence / horizon reset / theme toggle behaviours
//     reached through the (already-expanded) General group,
//   * deep-linking by key (including merged-away keys) opens the right pane,
//   * an unknown key falls back gracefully,
//   * the search box narrows to a real matching section.
//
// Why a stub AppSettingsNotifier instead of the real DB-backed one: the
// mutation tests need to write through the notifier and inspect the result
// without the network-backend branch tripping. The stub overrides only build();
// inherited setters still call _saveSetting → settingsDao and _patchState.
//
// Why we swallow "overflowed" FlutterErrors: some settings panes overflow a few
// pixels at the test surface size — a tracked cosmetic issue. We drop only
// "overflowed" errors and re-forward everything else so a real layout fault
// still trips takeException().

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/appearance_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/general_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/location_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/notification_routing_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/file_path_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/auto_save_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/autofocus_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/predictive_af_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';
import 'settings_sidebar_nav.dart';

/// Install a FlutterError.onError handler that drops "overflowed" layout
/// exceptions during the current test and re-forwards everything else.
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

/// In-memory [AppSettingsNotifier] that skips the database / network read path
/// and serves a fixed [AppSettingsState]. Tests mutate via the real setters so
/// the production validation path runs end-to-end; only the persistence
/// side-effects are short-circuited.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

List<Override> _stubSettings([
  AppSettingsState state = const AppSettingsState(),
]) {
  return [
    appSettingsProvider.overrideWith(() => _StubAppSettingsNotifier(state)),
  ];
}

/// Cancel the auto-save scheduler's timers.
///
/// The Files & Storage pane watches `autoSaveLifecycleProvider` — the only
/// provider that hydrates the persisted schedule — so rendering it genuinely
/// STARTS the host's backup scheduler, which arms periodic timers. Those
/// outlive the widget tree and trip flutter_test's pending-timer invariant,
/// which runs before tearDown callbacks, so the stop has to happen in the body.
void _stopAutoSave(HarnessHandle handle) {
  handle.container.read(autoSaveServiceProvider).dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'renders_without_throwing: default desktop pump is exception-free',
      (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(tester.takeException(), isNull,
        reason: 'Initial SettingsScreen pump under the default harness should '
            'not surface any uncaught exceptions.');
    // The first catalog section is General; its pane is the default selection.
    expect(find.byType(GeneralSettings), findsOneWidget,
        reason: 'The default selection must be the first catalog section '
            '(General).');
  });

  testWidgets(
      'grouped_sidebar_shows_all_seven_group_headers: every taxonomy group '
      'renders a collapsible header in the sidebar', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    // Group headers render in UPPER CASE in the sidebar.
    //
    // Scroll to each in turn rather than asserting all seven are on screen at
    // once: the sidebar is a lazy ListView.builder, so a header past the fold
    // simply is not built, and a bare `findsOneWidget` was passing only while
    // the whole taxonomy happened to fit the test surface. Walking the list is
    // also the stronger claim — it proves every group is REACHABLE, which is
    // what the user actually needs, at any row height or surface size.
    for (final title in const [
      'GENERAL',
      'EQUIPMENT',
      'IMAGING',
      'AUTOMATION & SAFETY',
      'SCIENCE',
      'NOTIFICATIONS & REMOTE',
      'ADVANCED',
    ]) {
      await revealInSettingsSidebar(tester, find.text(title));
      expect(find.text(title), findsOneWidget,
          reason: 'The grouped sidebar must show the "$title" group header.');
      expect(find.text(title).hitTestable(), findsOneWidget,
          reason: 'The "$title" group header must be tappable once scrolled '
              'to, not merely present in the widget tree.');
    }
  });

  testWidgets(
      'section_navigation_switches_content_pane: tapping a section in an '
      'expanded group swaps the detail pane', (tester) async {
    _swallowKnownOverflows();
    // The General group (containing the default General section) starts
    // expanded, so its Location entry is immediately tappable.
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(GeneralSettings), findsOneWidget,
        reason: 'Default pane is General.');
    expect(find.byType(LocationSettingsPage), findsNothing,
        reason: 'Location must not render before it is selected.');

    await tester.tap(find.text('Location').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byType(LocationSettingsPage), findsOneWidget,
        reason: 'Selecting the Location entry must swap the detail pane.');
    expect(find.byType(GeneralSettings), findsNothing,
        reason: 'The previous pane must be gone after switching.');
  });

  testWidgets(
      'form_validation_rejects_invalid_input: non-numeric latitude does not '
      'mutate AppSettingsState', (tester) async {
    _swallowKnownOverflows();
    const initial = AppSettingsState(latitude: 42.5, longitude: -71.0);

    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(initial),
    );

    await tester.tap(find.text('Location').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final latitudeInput = find.byType(SettingsNumberInput).first;
    final latitudeWidget = tester.widget<SettingsNumberInput>(latitudeInput);
    expect(latitudeWidget.controller.text, '42.5',
        reason: 'Latitude field must render the seeded value');
    final latField = find.descendant(
      of: latitudeInput,
      matching: find.byType(EditableText),
    );

    await tester.enterText(latField, 'abc');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final state = handle.container.read(appSettingsProvider).value;
    expect(state, isNotNull);
    expect(state!.latitude, 42.5,
        reason: 'Invalid (non-numeric) input must not propagate to state.');
  });

  testWidgets(
      'settings_load_from_defaults: default latitude renders in the location '
      'field', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    await tester.tap(find.text('Location').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byType(LocationSettingsPage), findsOneWidget);
    final latitudeInput = tester.widget<SettingsNumberInput>(
      find.byType(SettingsNumberInput).first,
    );
    expect(latitudeInput.controller.text, '0',
        reason: 'Default latitude (0.0) must render as "0".');
  });

  testWidgets(
      'valid_input_persists_to_state_and_db: setLatitude flows through to '
      'provider state and the DAO', (tester) async {
    _swallowKnownOverflows();
    const initial = AppSettingsState(latitude: 0.0, longitude: 0.0);

    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(initial),
    );

    await tester.tap(find.text('Location').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final latField = find.descendant(
      of: find.byType(SettingsNumberInput).first,
      matching: find.byType(EditableText),
    );
    await tester.enterText(latField, '47.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final state = handle.container.read(appSettingsProvider).value;
    expect(state, isNotNull);
    expect(state!.latitude, 47.5,
        reason: 'Valid input must propagate into AppSettingsState.');

    final dao = handle.container.read(settingsDaoProvider);
    final persisted = await dao.getSetting('observer_latitude');
    expect(persisted, isNotNull,
        reason: 'setLatitude must write a row to settingsDao.');
    expect(double.parse(persisted!), 47.5,
        reason:
            'The persisted DAO value must round-trip to the entered value.');
  });

  testWidgets(
      'horizon_reset_button_zeroes_all_directions: tapping "Reset All to 0°" '
      'writes a horizon JSON with every compass direction at 0.0',
      (tester) async {
    _swallowKnownOverflows();
    const initial = AppSettingsState(
      horizonProfileJson:
          '{"N":30.0,"NE":0.0,"E":0.0,"SE":0.0,"S":0.0,"SW":0.0,"W":0.0,"NW":0.0}',
    );

    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(initial),
    );

    await tester.tap(find.text('Location').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final resetButton = find.text('Reset All to 0°');
    expect(resetButton, findsOneWidget);
    await tester.ensureVisible(resetButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.tap(resetButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Discarding a horizon that is not already flat is confirmed first — the
    // button sits ~120 px from Import and there is no undo. See
    // location_horizon_reset_guard_test.dart.
    await tester.tap(find.text('Reset horizon'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final state = handle.container.read(appSettingsProvider).value;
    expect(state, isNotNull);
    final json = state!.horizonProfileJson;
    expect(json.contains('"N":30'), isFalse,
        reason: 'N=30 must be cleared after Reset All to 0°.');
    for (final dir in const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']) {
      expect(json.contains('"$dir":0'), isTrue,
          reason: 'Direction "$dir" must be reset to 0 in the horizon JSON.');
    }
  });

  testWidgets(
      'theme_dropdown_selects_red_night: choosing "Red night" in the '
      'Appearance theme dropdown flips AppSettingsState.theme through '
      'setTheme()', (tester) async {
    _swallowKnownOverflows();
    const initial = AppSettingsState();
    expect(initial.theme, 'dark', reason: 'Sanity: the default theme is dark.');

    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(initial),
    );

    // Appearance is in the (already-expanded) General group.
    await tester.tap(find.text('Appearance').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(AppearanceSettings), findsOneWidget);

    // The Dark on/off switch was replaced by a three-way theme selector
    // (Dark / Light / Red night) so the red-night mode — built for a dark
    // site — is finally reachable. Open it and pick Red night.
    await tester.tap(find.text('Dark').first);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await tester.tap(find.text('Red night').last);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    final state = handle.container.read(appSettingsProvider).value;
    expect(state, isNotNull);
    expect(state!.theme, 'redNight',
        reason: 'Selecting "Red night" must fire setTheme("redNight").');
  });

  // Deep-linking by stable KEY (the navigation contract).

  testWidgets(
      'deep_link_opens_target_section: initialSection "location" renders the '
      'Location pane directly with no sidebar interaction', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(initialSection: 'location'),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(LocationSettingsPage), findsOneWidget,
        reason: 'initialSection "location" must open the Location pane.');
    expect(find.byType(GeneralSettings), findsNothing,
        reason: 'The default General pane must not render when deep-linked.');
  });

  testWidgets(
      'deep_link_unknown_section_falls_back_to_first: an unrecognised key '
      'opens the default (first) pane without crashing', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(initialSection: 'does-not-exist'),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(GeneralSettings), findsOneWidget,
        reason: 'An unknown key must fall back to the first section, not throw '
            'or render a blank pane.');
  });

  testWidgets(
      'merged_key_file_paths_opens_files_and_storage: deep-linking the '
      'merged-away "file-paths" key opens the combined Files & Storage section '
      '(both child widgets present)', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(initialSection: 'file-paths'),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(FilePathSettings), findsOneWidget,
        reason: '"file-paths" must resolve to the combined section that '
            'contains FilePathSettings.');
    expect(find.byType(AutoSaveSettings), findsOneWidget,
        reason: 'The combined Files & Storage section also stacks '
            'AutoSaveSettings.');

    _stopAutoSave(handle);
  });

  testWidgets(
      'merged_key_auto_save_opens_files_and_storage: the second merged-away key '
      'also lands on Files & Storage', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const SettingsScreen(initialSection: 'auto-save'),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(FilePathSettings), findsOneWidget);
    expect(find.byType(AutoSaveSettings), findsOneWidget);
    expect(find.text('Enable sequence auto-save'), findsOneWidget);
    expect(find.text('Sequence save interval'), findsOneWidget);

    _stopAutoSave(handle);
  });

  testWidgets(
      'merged_key_predictive_af_opens_autofocus: "predictive-af" resolves to '
      'the combined Autofocus section', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(initialSection: 'predictive-af'),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(AutofocusSettingsPage), findsOneWidget,
        reason: '"predictive-af" must open the combined Autofocus section.');
    expect(find.byType(PredictiveAfSettingsPage), findsOneWidget,
        reason: 'The combined Autofocus section also stacks the predictive '
            'autofocus page.');
  });

  testWidgets(
      'merged_key_notification_routing_opens_notifications: '
      '"notification-routing" resolves to the combined Notifications section',
      (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(initialSection: 'notification-routing'),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    expect(find.byType(NotificationSettings), findsOneWidget,
        reason: '"notification-routing" must open the combined Notifications '
            'section.');
    expect(find.byType(NotificationRoutingSettings), findsOneWidget,
        reason: 'The combined Notifications section also stacks the routing '
            'matrix.');
  });

  // Search.

  testWidgets(
      'search_filters_to_a_real_section: typing a keyword narrows the sidebar '
      'to a matching section and selecting it opens its pane', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1280, 800),
      extraOverrides: _stubSettings(),
    );

    // "latitude" is a Location keyword; the Equipment group (with Connection)
    // is collapsed by default, so this proves search bypasses grouping.
    final searchField = find.byType(TextField).first;
    await tester.enterText(searchField, 'latitude');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // The flat result list shows Location and lets us open it.
    final locationResult = find.text('Location');
    expect(locationResult, findsOneWidget,
        reason: 'Searching "latitude" must surface the Location section.');

    await tester.tap(locationResult);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(LocationSettingsPage), findsOneWidget,
        reason: 'Selecting a search result must open that section.');
  });

  // Derived index shim (kept only for backward compatibility).

  test(
      'kSettingsSectionIndex maps every stable key (incl. merged-away aliases) '
      'to a non-negative index', () {
    for (final key in const [
      'general',
      'appearance',
      'location',
      'files-storage',
      'help',
      'about',
      'connection',
      'equipment-profiles',
      'phd2-guiding',
      'plate-solving',
      'autofocus',
      'calibration',
      'dark-library',
      'imaging',
      'catalogs',
      'sequencer',
      'weather-safety',
      'science',
      'notifications',
      'integrations',
      'remote-access',
      'logs',
      // Merged-away aliases share their combined section's index.
      'file-paths',
      'auto-save',
      'predictive-af',
      'focus-model',
      'notification-routing',
    ]) {
      expect(kSettingsSectionIndex[key], isNotNull,
          reason: 'Key "$key" must resolve in the derived index shim.');
      expect(kSettingsSectionIndex[key]! >= 0, isTrue);
    }

    // Merged-away aliases resolve to their combined section's index.
    expect(kSettingsSectionIndex['file-paths'],
        kSettingsSectionIndex['files-storage']);
    expect(kSettingsSectionIndex['auto-save'],
        kSettingsSectionIndex['files-storage']);
    expect(kSettingsSectionIndex['predictive-af'],
        kSettingsSectionIndex['autofocus']);
    expect(kSettingsSectionIndex['focus-model'],
        kSettingsSectionIndex['autofocus']);
    expect(kSettingsSectionIndex['notification-routing'],
        kSettingsSectionIndex['notifications']);
  });
}
