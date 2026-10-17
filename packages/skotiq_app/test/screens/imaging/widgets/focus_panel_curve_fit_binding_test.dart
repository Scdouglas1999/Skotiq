// The imaging Focus panel's autofocus curve-fit control must show the strategy
// the run will actually use.
//
// Binding it to `FocusSettings.method` gets both halves wrong: that field is
// seeded from `AppSettings.afMethod`, the star METRIC, whose only legal value is
// 'Star HFR', so against ['V-Curve', 'Hyperbolic', 'Parabolic']
// `items.contains(value)` is false and the closed dropdown renders blank on
// every launch — and picking a value there changes nothing about the run, since
// `_runAutofocus` resolves the curve fit from `AppSettings.afCurveFitting` and
// the FFI backend maps THAT value onto the native curve enum
// (`autofocusCurveMethodForNativeBridge`).
//
// So the control is bound to `afCurveFitting`, shares one vocabulary with the
// Settings screen (`AutofocusSettings.curveFittingOptions`), and writes edits
// back to the persisted setting.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/focus_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockDeviceService extends Mock implements DeviceService {}

/// Settings notifier pinned to a known persisted autofocus configuration.
class _FakeSettingsNotifier extends AppSettingsNotifier {
  _FakeSettingsNotifier([this._curveFitting = 'Hyperbolic']);

  final String _curveFitting;

  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(afCurveFitting: _curveFitting);
}

/// Settings notifier that never completes, standing in for the window before
/// the persisted settings have loaded.
class _PendingSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() => Completer<AppSettingsState>().future;
}

/// Session state pinned to "autofocus in progress".
class _AutofocusingSessionNotifier extends SessionStateNotifier {
  _AutofocusingSessionNotifier(super.ref) {
    state = const SessionState(isAutofocusing: true);
  }
}

/// The Curve fit row's dropdown, read straight off the widget tree so the test
/// asserts on the real bound value/items/callback rather than rendered glyphs.
SkotiqDropdown _curveFitDropdown(WidgetTester tester) {
  final row = tester.widget<DropdownRow>(
    find.ancestor(
      of: find.text('Curve fit'),
      matching: find.byType(DropdownRow),
    ),
  );
  return tester.widget<SkotiqDropdown>(
    find.descendant(
      of: find.byWidget(row),
      matching: find.byType(SkotiqDropdown),
    ),
  );
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  String curveFitting = 'Parabolic',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeSettingsNotifier(curveFitting)),
        deviceServiceProvider.overrideWithValue(_MockDeviceService()),
        // The panel now also carries the temperature-compensation card, which
        // is profile-scoped. This file is about the curve-fit dropdown only, so
        // pin the profile to "none" and let the card render its empty state
        // instead of standing up the profiles database.
        activeEquipmentProfileProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: FocusPanel(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the persisted curve-fit strategy, not a blank control',
      (tester) async {
    await _pumpPanel(tester, curveFitting: 'Parabolic');

    expect(find.text('Curve fit'), findsOneWidget);
    // The saved value is rendered in the closed dropdown.
    expect(find.text('Parabolic'), findsOneWidget);
    // The star metric must never be offered as a curve fit.
    expect(find.textContaining('Star HFR'), findsNothing);
    expect(find.text('Autofocus settings are still loading.'), findsNothing);
  });

  testWidgets('renders the Trend Lines strategy the Settings screen can save',
      (tester) async {
    // 'Trend Lines' is a legal persisted value that the panel's old
    // ['V-Curve', ...] vocabulary could not display at all.
    await _pumpPanel(tester, curveFitting: 'Trend Lines');

    expect(find.text('Trend Lines'), findsOneWidget);
  });

  testWidgets('offers exactly the persisted vocabulary', (tester) async {
    await _pumpPanel(tester, curveFitting: 'Hyperbolic');

    final dropdown = _curveFitDropdown(tester);
    // Every option the panel offers must be a value the autofocus run can
    // resolve, so it reads the SHARED list rather than a private copy — a
    // private list can carry entries like 'V-Curve' that no persisted value
    // ever equals.
    expect(dropdown.items, AutofocusSettings.curveFittingOptions);
    expect(dropdown.items, isNot(contains('V-Curve')));
    // And the value it renders is drawn from that same vocabulary, so the
    // closed control can never be blank for a valid saved setting.
    expect(dropdown.items, contains(dropdown.value));
  });

  testWidgets('an edit is written through to the persisted setting',
      (tester) async {
    // Real settings notifier over an in-memory database, so the edit travels
    // the production write path (`setAfCurveFitting` -> settings DAO ->
    // patched state) instead of a stub that could hide a dead control.
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          deviceServiceProvider.overrideWithValue(_MockDeviceService()),
          // See _pumpPanel: the temperature-compensation card is
          // profile-scoped, and this test is about the curve-fit write path.
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: FocusPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_curveFitDropdown(tester).value, 'Hyperbolic');

    _curveFitDropdown(tester).onChanged!('Parabolic');
    await tester.pumpAndSettle();

    // The control reflects the new choice...
    expect(_curveFitDropdown(tester).value, 'Parabolic');
    // ...and it is the persisted `afCurveFitting` the autofocus run resolves
    // its curve from, not an in-memory panel-only field.
    final saved = await database.settingsDao.getSetting('af_curve_fitting');
    expect(saved, 'Parabolic');
  });

  testWidgets('the control is disabled while a run is in flight',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_FakeSettingsNotifier.new),
          deviceServiceProvider.overrideWithValue(_MockDeviceService()),
          sessionStateProvider.overrideWith(
            (ref) => _AutofocusingSessionNotifier(ref),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: FocusPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Changing the fit strategy mid-sweep would describe the run wrongly.
    expect(_curveFitDropdown(tester).onChanged, isNull);
  });

  testWidgets('says settings are loading instead of showing an empty control',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(_PendingSettingsNotifier.new),
          deviceServiceProvider.overrideWithValue(_MockDeviceService()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: FocusPanel(colors: SkotiqColors.dark),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Curve fit'), findsOneWidget);
    expect(find.text('Autofocus settings are still loading.'), findsOneWidget);
  });
}
