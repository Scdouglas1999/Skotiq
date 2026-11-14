import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'session_test_support.dart';

/// The legend under Tonight's cooling chart for a camera whose cooler reads
/// `coolerOn`.
List<String> legendFor(bool? coolerOn) {
  final container = ProviderContainer(
    overrides: <Override>[
      cameraStateProvider.overrideWith(
        (ref) => FixedCamera(
          ref,
          CameraStateSnapshot(
            connectionState: DeviceConnectionState.connected,
            deviceName: 'ZWO ASI1600MM Pro',
            temperature: -10.5,
            targetTemp: -10,
            coolerOn: coolerOn,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(temperatureHistoryProvider.notifier)
      .addPoint(-10.5, targetTemp: coolerOn == null ? null : -10);
  return container
      .read(nightCoolerHistoryProvider)
      .legend
      .map((metric) => metric.label.key)
      .toList();
}

void main() {
  test('a cooler the camera cannot read back is not said to be off', () {
    expect(legendFor(null), isNot(contains('nightSessionCoolerOff')));
    expect(legendFor(null), isNot(contains('nightSessionSetpoint')));
  });

  test('a cooler the camera reads as off or on is said to be so', () {
    expect(legendFor(false), contains('nightSessionCoolerOff'));
    expect(legendFor(true), contains('nightSessionSetpoint'));
    expect(legendFor(true), isNot(contains('nightSessionCoolerOff')));
  });
}
