// Weather must not hide live sensor data behind the location gate.
//
// With a weather station connected and its card on Equipment showing
// temperature / humidity / cloud cover / rain rate, a profile with no observing
// location must still render the station's readings and the safety verdict —
// neither needs a location. Only the radar does, so only the radar gets the
// "No observing site" empty state.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

class _FakeWeatherNotifier extends StateNotifier<WeatherState>
    implements WeatherStateNotifier {
  _FakeWeatherNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('sensors and safety stay visible without a location',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const WeatherScreen(),
      registerTearDown: false,
      size: const Size(1400, 1000),
      settle: false,
      extraOverrides: [
        weatherStateProvider.overrideWith(
          (ref) => _FakeWeatherNotifier(
            const WeatherState(
              connectionState: DeviceConnectionState.connected,
              deviceId: 'sim:weather:1',
              deviceName: 'Simulated Weather Station',
            ),
          ),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.text('No observing site'),
      findsOneWidget,
      reason: 'the radar genuinely does need a location',
    );
    expect(
      find.text('CONDITIONS'),
      findsOneWidget,
      reason: 'a connected weather station reports without knowing where it is',
    );

    // The screen owns polling timers; tear it down inside the test body so the
    // binding's pending-timer check sees a disposed tree.
    await tester.pumpWidget(const SizedBox.shrink());
    handle.container.dispose();
    // Drift schedules a zero-duration close timer when its query streams go; one
    // more frame lets it run before the binding checks for pending timers.
    await tester.pump(Duration.zero);
  });
}
