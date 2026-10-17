// The Framing FOV provider must not re-query the camera on telemetry churn.
//
// `framingFOVProvider` watched the WHOLE `cameraStateProvider` snapshot to read
// two fields off it (connection state and device name), so every sensor
// temperature / cooler power / exposure progress tick invalidated the provider
// and re-ran its async `getCameraStatus` round trip. The Framing sidebar's
// Equipment card then spent most of its life mid-reload — eight of ten samples
// over 30 s were a bare spinner — for data that only changes when the camera
// connects, disconnects or is renamed.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

const _status = CameraStatus(
  connected: true,
  state: CameraState.idle,
  coolerOn: false,
  gain: 100,
  offset: 10,
  binX: 1,
  binY: 1,
  sensorWidth: 1920,
  sensorHeight: 1080,
  pixelSizeX: 3.76,
  pixelSizeY: 3.76,
  maxAdu: 65535,
  canCool: true,
  canSetGain: true,
  canSetOffset: true,
);

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'My First Rig',
  isActive: true,
  cameraId: 'sim_camera_1',
  focalLength: 530,
  aperture: 106,
);

void main() {
  setUpAll(registerMocktailFallbackValues);

  test('camera telemetry ticks do not re-query the camera for FOV', () async {
    final backend = MockBackend();
    var statusQueries = 0;
    when(() => backend.getCameraStatus(any())).thenAnswer((_) async {
      statusQueries++;
      return _status;
    });

    late CameraStateNotifier camera;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
        cameraStateProvider.overrideWith((ref) {
          camera = CameraStateNotifier(ref)
            ..setConnecting('sim_camera_1', 'Simulated Camera')
            ..setConnected();
          return camera;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(framingFOVProvider, (_, _) {});

    final first = await container.read(framingFOVProvider.future);
    expect(first.isReady, isTrue, reason: 'precondition: the FOV resolved');
    expect(statusQueries, 1);

    // A night's worth of ordinary telemetry: cooling, then an exposure.
    camera
      ..updateTemperature(-9.2, 61)
      ..updateTemperature(-9.6, 64)
      ..setExposing(true, progress: 0.25)
      ..setExposing(true, progress: 0.5);
    await Future<void>.delayed(Duration.zero);
    await container.read(framingFOVProvider.future);

    expect(
      statusQueries,
      1,
      reason:
          'none of these changed the sensor, its name, or whether it is '
          'connected — but each one re-ran the whole async provider, which is '
          'what made the Equipment card read as permanently loading',
    );
  });

  // The narrowed watch must still NOTICE a disconnect. Framing does not
  // require a live camera, so the noticed state is "these are the values I
  // remember" rather than `noCameraSpecs` — framing and mosaic planning stay
  // usable with the rig packed away.
  test('a disconnect still re-runs it', () async {
    final backend = MockBackend();
    var statusQueries = 0;
    when(() => backend.getCameraStatus(any())).thenAnswer((_) async {
      statusQueries++;
      return _status;
    });

    late CameraStateNotifier camera;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _FixedBackend(ref, backend)),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
        cameraStateProvider.overrideWith((ref) {
          camera = CameraStateNotifier(ref)
            ..setConnecting('sim_camera_1', 'Simulated Camera')
            ..setConnected();
          return camera;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(framingFOVProvider, (_, _) {});

    expect((await container.read(framingFOVProvider.future)).isReady, isTrue);

    camera.setDisconnected();
    await Future<void>.delayed(Duration.zero);
    final after = await container.read(framingFOVProvider.future);

    expect(
      after.message,
      contains('remembered'),
      reason:
          'narrowing the watch must not make the card go stale — pulling '
          'the camera has to be noticed, and the card has to say the specs '
          'are now last-seen values rather than live ones',
    );
    expect(statusQueries, 1, reason: 'a disconnected camera is not queried');
  });
}

/// Keeps the provider graph on one backend for the test's life.
class _FixedBackend extends BackendNotifier {
  _FixedBackend(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
