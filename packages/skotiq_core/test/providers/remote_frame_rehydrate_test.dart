// The periodic re-hydrate does not download the host's last frame; first
// connect and a reconnect do, and a frame already on screen is not published
// again.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _cameraId = 'native:zwo:1';

final _frame = CapturedImageResult(
  width: 2,
  height: 1,
  displayData: List<int>.filled(8, 255),
  histogram: List<int>.filled(256, 0),
  stats: const ImageStatsResult(
    min: 0,
    max: 1,
    mean: 0.5,
    median: 0.5,
    stdDev: 0.1,
    starCount: 0,
  ),
  exposureTime: 2,
  timestamp: '2026-10-21T08:43:29Z',
);

({_MockNetworkBackend backend, ProviderContainer container}) _setUp() {
  final backend = _MockNetworkBackend();
  when(
    () => backend.sequencerGetStatus(),
  ).thenAnswer((_) async => const SequencerStatus(state: 'Idle', progress: 0));
  when(() => backend.getConnectedDevices()).thenAnswer(
    (_) async => const [
      DeviceInfo(
        id: _cameraId,
        name: 'ZWO ASI1600MM-Cool',
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        description: '',
        driverVersion: '1.0',
      ),
    ],
  );
  when(
    () => backend.cameraGetLastImage(_cameraId),
  ).thenAnswer((_) async => _frame);
  when(
    () => backend.getLastRawImageData(_cameraId),
  ).thenAnswer((_) async => Uint16List(2));
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);

  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
  );
  addTearDown(container.dispose);
  return (backend: backend, container: container);
}

Future<void> _hydrate(
  ProviderContainer container,
  NetworkBackend backend, {
  required bool refreshCurrentFrame,
}) async {
  try {
    await hydrateRemoteSessionState(
      container,
      backend,
      refreshCurrentFrame: refreshCurrentFrame,
    );
  } catch (_) {
    // The planner/profile fan-out after the frame step is not stubbed here;
    // only the frame fetch matters to these tests.
  }
  await pumpEventQueue();
}

void main() {
  test('the periodic re-hydrate does not fetch the last frame', () async {
    final (:backend, :container) = _setUp();

    await _hydrate(container, backend, refreshCurrentFrame: false);

    verifyNever(() => backend.cameraGetLastImage(any()));
    verifyNever(() => backend.getLastRawImageData(any()));
  });

  test(
    'first connect fetches it once, and the same frame is not republished',
    () async {
      final (:backend, :container) = _setUp();

      await _hydrate(container, backend, refreshCurrentFrame: true);
      final shown = container.read(currentImageProvider);
      expect(shown, isNotNull);
      verify(() => backend.cameraGetLastImage(_cameraId)).called(1);
      verify(() => backend.getLastRawImageData(_cameraId)).called(1);

      // A reconnect asks again; the host still has the same frame.
      await _hydrate(container, backend, refreshCurrentFrame: true);

      verify(() => backend.cameraGetLastImage(_cameraId)).called(1);
      verifyNever(() => backend.getLastRawImageData(any()));
      expect(
        container.read(currentImageProvider)?.capturedAt,
        shown!.capturedAt,
      );
    },
  );
}
