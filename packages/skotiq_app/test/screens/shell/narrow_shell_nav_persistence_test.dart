// The narrow shell's bottom nav does not go away.
//
// Every narrow screen — Sequencer, Guiding, Equipment, Settings, Tonight —
// painted a grabber handle above the bottom nav
// (reports/observatory/integration-3/m_*.png), and tapping it collapsed the
// nav behind a "Menu" pill. Only Imaging's controls sheet has a grabber in
// narrow.png, and that grabber belongs to the SHEET. 04 §3.3 gives the narrow
// shell a bottom nav; below 768px it IS the navigation, so an affordance that
// takes it away is one an operator can only lose by.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/screens/shell/widgets/skotiq_bottom_navigation.dart';
import 'package:skotiq_app/screens/shell/widgets/side_navigation.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// The real notifier re-evaluates on construction and schedules a timer that
/// outlives the widget tree; the narrow shell mounts the weather banner, and
/// this test is about the navigation, not about safety.
class _PinnedSafetyNotifier extends WeatherSafetyNotifier {
  _PinnedSafetyNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    super.state = const WeatherSafetyState(
      status: WeatherSafetyStatus.safe,
      actions: WeatherSafetyActions(),
      currentAlertLevel: AlertLevel.clear,
      dataSource: SafetyDataSource.unavailable,
      monitoringEnabled: false,
    );
    _pinned = true;
  }

  bool _pinned = false;

  @override
  set state(WeatherSafetyState value) {
    if (_pinned) return;
    super.state = value;
  }
}

final _quiet = <Override>[
  activeTransientAlertsProvider.overrideWith(
    (ref) => Stream.value(const <TransientAlert>[]),
  ),
  railWeatherUnsafeProvider.overrideWithValue(false),
  railAnyDeviceConnectedProvider.overrideWithValue(true),
  weatherSafetyProvider.overrideWith(_PinnedSafetyNotifier.new),
];

void main() {
  testWidgets('a 700x900 shell shows the nav and no way to hide it', (
    tester,
  ) async {
    final handle = await pumpAppScreen(
      tester,
      const AppShell(child: Text('Routed content')),
      settle: false,
      extraOverrides: _quiet,
      size: const Size(700, 900),
      // This test owns the teardown: the shell's weather-safety and
      // co-imaging providers run 5-minute periodic timers, and the binding
      // checks for pending timers BEFORE any addTearDown callback fires.
      registerTearDown: false,
    );
    // The database close is a dart:io future and never completes inside the
    // fake-async zone, so it belongs in a tear-down; only the container has
    // to be disposed in the body, because only IT owns timers.
    addTearDown(handle.database.close);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(SkotiqBottomNavigation), findsOneWidget);

    // The pill the handle collapsed the nav into. Its absence is the point:
    // there is no state in which the nav is not on screen.
    expect(find.text('Menu'), findsNothing);

    // And the handle itself is gone with it — nothing in the shell offers to
    // hide the navigation.
    expect(
      find.byIcon(SkotiqIcons.chevronDown),
      findsNothing,
      reason: 'the shell drew a grabber chevron above the nav on every screen',
    );
    expect(find.byIcon(SkotiqIcons.chevronUp), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
    handle.container.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  });
}
