import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/weather_safety_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

/// The SAFETY pill used to switch on `status` alone, so a rig with no weather
/// source at all wore a green "Safe" check directly above its own
/// "Data: Unavailable" / "conditions are not being checked" body text.
class _FixedSafetyNotifier extends WeatherSafetyNotifier {
  _FixedSafetyNotifier(super.ref, WeatherSafetyState fixed) {
    // ignore: invalid_use_of_protected_member
    super.state = fixed;
    _pinned = true;
  }

  /// The real notifier re-evaluates on construction and would overwrite the
  /// snapshot under test; pin it so the card renders exactly what we seeded.
  bool _pinned = false;

  @override
  set state(WeatherSafetyState value) {
    if (_pinned) return;
    super.state = value;
  }
}

WeatherSafetyState _state({
  required WeatherSafetyStatus status,
  required bool monitoringEnabled,
  required SafetyDataSource dataSource,
}) =>
    WeatherSafetyState(
      status: status,
      actions: const WeatherSafetyActions(),
      currentAlertLevel: AlertLevel.clear,
      dataSource: dataSource,
      monitoringEnabled: monitoringEnabled,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runDashboardSafetyBadge', () {
    test('monitoring off is never green, whatever the status says', () {
      expect(
        runDashboardSafetyBadge(
          status: WeatherSafetyStatus.safe,
          monitoringEnabled: false,
          dataSource: SafetyDataSource.unavailable,
        ),
        RunDashboardSafetyBadge.notMonitored,
      );
    });

    test('monitoring on but no source resolves to noData, not safe', () {
      expect(
        runDashboardSafetyBadge(
          status: WeatherSafetyStatus.safe,
          monitoringEnabled: true,
          dataSource: SafetyDataSource.unavailable,
        ),
        RunDashboardSafetyBadge.noData,
      );
    });

    test('a real safe reading is still green', () {
      expect(
        runDashboardSafetyBadge(
          status: WeatherSafetyStatus.safe,
          monitoringEnabled: true,
          dataSource: SafetyDataSource.hardwareWeather,
        ),
        RunDashboardSafetyBadge.safe,
      );
    });

    test('unsafe and snoozed survive a missing source', () {
      expect(
        runDashboardSafetyBadge(
          status: WeatherSafetyStatus.unsafe,
          monitoringEnabled: true,
          dataSource: SafetyDataSource.unavailable,
        ),
        RunDashboardSafetyBadge.unsafe,
      );
      expect(
        runDashboardSafetyBadge(
          status: WeatherSafetyStatus.snoozed,
          monitoringEnabled: true,
          dataSource: SafetyDataSource.unavailable,
        ),
        RunDashboardSafetyBadge.snoozed,
      );
    });
  });

  /// The real WeatherSafetyNotifier keeps periodic timers alive, so these
  /// tests own the container lifecycle and tear it down inside the test body
  /// (the harness's teardown runs after the pending-timer invariant check).
  Future<HarnessHandle> pumpCard(
      WidgetTester tester, WeatherSafetyState safety) async {
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: RunDashboardWeatherSafetyCard()),
      registerTearDown: false,
      extraOverrides: [
        // A DisconnectedBackend makes WeatherSafetyNotifier's constructor take
        // its passive early-return branch: no alert subscription, no periodic
        // evaluation, no cloud-motion push — none of which this test is about,
        // and all of which leak timers/futures into the test isolate.
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
        ),
        weatherSafetyProvider.overrideWith(
          (ref) => _FixedSafetyNotifier(ref, safety),
        ),
      ],
    );
    return handle;
  }

  /// Must run INSIDE the test body: the pending-timer invariant is checked
  /// before addTearDown callbacks run.
  Future<void> disposeCard(WidgetTester tester, HarnessHandle handle) async {
    await tester.pumpWidget(const SizedBox.shrink());
    handle.container.dispose();
    await handle.database.close();
  }

  testWidgets('card with no weather source does not render a green Safe pill',
      (tester) async {
    final handle = await pumpCard(
      tester,
      _state(
        status: WeatherSafetyStatus.safe,
        monitoringEnabled: false,
        dataSource: SafetyDataSource.unavailable,
      ),
    );

    expect(find.text('Safe'), findsNothing);
    expect(find.text('Not monitored'), findsOneWidget);
    await disposeCard(tester, handle);
  });

  testWidgets('card with a live safe reading still says Safe', (tester) async {
    final handle = await pumpCard(
      tester,
      _state(
        status: WeatherSafetyStatus.safe,
        monitoringEnabled: true,
        dataSource: SafetyDataSource.hardwareWeather,
      ),
    );

    expect(find.text('Safe'), findsOneWidget);
    await disposeCard(tester, handle);
  });
}
