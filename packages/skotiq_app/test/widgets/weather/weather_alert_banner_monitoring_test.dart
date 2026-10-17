// With weather safety switched OFF and 100% cloud cover, the shell pinned
// "Weather Critical / Weather safety is off" above every route while the
// Weather screen itself said "Not monitored". A monitor that is off has no
// verdict to raise a global alert with, so the banner must stay hidden.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/weather/weather_alert_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _FixedSafetyNotifier extends WeatherSafetyNotifier {
  _FixedSafetyNotifier(super.ref, WeatherSafetyState fixed) {
    // ignore: invalid_use_of_protected_member
    super.state = fixed;
    _pinned = true;
  }

  bool _pinned = false;

  @override
  set state(WeatherSafetyState value) {
    if (_pinned) return;
    super.state = value;
  }
}

WeatherSafetyState _critical({required bool monitoringEnabled}) =>
    WeatherSafetyState(
      status: WeatherSafetyStatus.safe,
      actions: const WeatherSafetyActions(
        reason: 'Weather safety is off — conditions are not being checked',
      ),
      currentAlertLevel: AlertLevel.critical,
      monitoringEnabled: monitoringEnabled,
    );

void main() {
  Future<HarnessHandle> pumpBanner(
      WidgetTester tester, WeatherSafetyState safety) async {
    final handle = await pumpAppScreen(
      tester,
      const WeatherAlertBanner(),
      registerTearDown: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
        ),
        weatherSafetyProvider.overrideWith(
          (ref) => _FixedSafetyNotifier(ref, safety),
        ),
      ],
    );
    await tester.pump(const Duration(seconds: 1));
    return handle;
  }

  Future<void> dispose(WidgetTester tester, HarnessHandle handle) async {
    await tester.pumpWidget(const SizedBox.shrink());
    handle.container.dispose();
    await handle.database.close();
  }

  testWidgets('monitoring off hides the banner even at a critical level',
      (tester) async {
    final handle =
        await pumpBanner(tester, _critical(monitoringEnabled: false));
    expect(find.text('Weather Critical'), findsNothing);
    await dispose(tester, handle);
  });

  testWidgets('monitoring on shows the banner at a critical level',
      (tester) async {
    final handle = await pumpBanner(tester, _critical(monitoringEnabled: true));
    expect(find.text('Weather Critical'), findsOneWidget);
    await dispose(tester, handle);
  });
}
