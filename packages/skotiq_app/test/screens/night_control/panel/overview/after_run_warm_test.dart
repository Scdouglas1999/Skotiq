// "Warm camera…" after a run asks the operator to warm a cold camera. While
// the end-of-night warm-up is already ramping the cooler, it has nothing to
// ask, and offering it read as though the warm-up had not started.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/after_run_section.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

class _FixedCamera extends CameraStateNotifier {
  _FixedCamera(super.ref, CameraStateSnapshot snapshot) {
    state = snapshot;
  }
}

bool coolerOn(CameraStateSnapshot camera) {
  final container = ProviderContainer(overrides: [
    cameraStateProvider.overrideWith((ref) => _FixedCamera(ref, camera)),
    allSessionsProvider.overrideWith((ref) => Stream.value(const [])),
  ]);
  addTearDown(container.dispose);
  return container.read(nightAfterRunProvider).coolerOn;
}

void main() {
  test('a cold camera is offered a warm-up', () {
    expect(
      coolerOn(const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        coolerOn: true,
      )),
      isTrue,
    );
  });

  test('a camera already warming up is not', () {
    expect(
      coolerOn(const CameraStateSnapshot(
        connectionState: DeviceConnectionState.connected,
        coolerOn: true,
        isWarming: true,
      )),
      isFalse,
    );
  });
}
