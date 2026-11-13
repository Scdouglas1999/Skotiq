import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import '../harness/in_memory_database.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A linked client has no capture loop of its own, so its host's imaging
/// events are its only source for the camera card's "Exposing" and the
/// countdown ([applyHostEventOnClient]). The host follows the same events
/// only for an exposure it did not start ([applyHostLocalSyncEvent]).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NetworkBackend slaveBackend() =>
      NetworkBackend(serverHost: '127.0.0.1', serverPort: 8080);

  SkotiqEvent imagingEvent(String type, Map<String, dynamic> data) =>
      SkotiqEvent(
        timestamp: 0,
        severity: EventSeverity.info,
        category: EventCategory.imaging,
        eventType: type,
        data: data,
      );

  test(
    'ExposureStarted marks the camera exposing and seeds the countdown',
    () async {
      final backend = slaveBackend();
      addTearDown(backend.dispose);
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      applyHostEventOnClient(container, backend, imagingEvent('ExposureStarted', {
          'duration_secs': 60.0,
          'frame_type': 'light',
          'frame': 3,
          'total': 10,
        }));

      expect(container.read(cameraStateProvider).isExposing, isTrue);
      final progress = container.read(exposureProgressProvider);
      expect(progress.remaining, 60.0);
      expect(progress.frameNumber, 3);
      expect(progress.totalFrames, 10);
    },
  );

  test('ExposureProgress drives the live remaining-time countdown', () async {
    final backend = slaveBackend();
    addTearDown(backend.dispose);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    applyHostEventOnClient(container, backend, imagingEvent('ExposureProgress', {
        'progress': 0.25,
        'remainingSecs': 45.0,
      }));

    final camera = container.read(cameraStateProvider);
    expect(camera.isExposing, isTrue);
    expect(camera.exposureProgress, 0.25);
    final progress = container.read(exposureProgressProvider);
    expect(progress.remaining, 45.0);
    expect(progress.percent, closeTo(25.0, 0.001));
  });

  test('ExposureComplete clears the exposing state', () async {
    final backend = slaveBackend();
    addTearDown(backend.dispose);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    applyHostEventOnClient(container, backend, imagingEvent('ExposureProgress', {
        'progress': 0.5,
        'remainingSecs': 30.0,
      }));
    expect(container.read(cameraStateProvider).isExposing, isTrue);

    applyHostEventOnClient(container, backend, imagingEvent('ExposureComplete', const {}));
    expect(container.read(cameraStateProvider).isExposing, isFalse);
    expect(
      container.read(exposureProgressProvider),
      ExposureProgress.idle(),
      reason: 'the last countdown must not outlive the frame',
    );
  });

  for (final ending in <String>['ExposureCancelled', 'ExposureFailed']) {
    test('$ending ends the mirrored exposure', () async {
      final backend = slaveBackend();
      addTearDown(backend.dispose);
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      applyHostEventOnClient(container, backend, imagingEvent('ExposureProgress', {
          'progress': 0.5,
          'remainingSecs': 30.0,
        }));
      applyHostEventOnClient(container, backend, imagingEvent(ending, const {'error': 'driver fault'}));

      expect(container.read(cameraStateProvider).isExposing, isFalse);
      expect(container.read(exposureProgressProvider), ExposureProgress.idle());
    });
  }

  test(
    'exposure events are IGNORED on the host path (no network backend)',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      applyHostLocalSyncEvent(container, imagingEvent('ExposureProgress', {
          'progress': 0.5,
          'remainingSecs': 30.0,
        }));

      expect(container.read(cameraStateProvider).isExposing, isFalse);
    },
  );
}
