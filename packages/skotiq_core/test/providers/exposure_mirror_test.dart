import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Tests for the slave-side per-frame exposure-countdown mirror
/// (`_applyExposureMirror`, reached via [applyRemoteSyncEvent] for
/// imaging-category exposure events). A remote companion has no local capture
/// loop, so these host events are the slave's ONLY source for the camera card's
/// "Exposing" status and the remaining-time countdown. The mirror is gated on a
/// non-null [NetworkBackend] so it never double-applies on the host (where
/// ImagingService already owns this state).
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

      await applyRemoteSyncEvent(
        container,
        imagingEvent('ExposureStarted', {
          'durationSecs': 60.0,
          'frameNumber': 3,
          'totalFrames': 10,
        }),
        networkBackend: backend,
      );

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

    await applyRemoteSyncEvent(
      container,
      imagingEvent('ExposureProgress', {
        'progress': 0.25,
        'remainingSecs': 45.0,
      }),
      networkBackend: backend,
    );

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

    await applyRemoteSyncEvent(
      container,
      imagingEvent('ExposureProgress', {
        'progress': 0.5,
        'remainingSecs': 30.0,
      }),
      networkBackend: backend,
    );
    expect(container.read(cameraStateProvider).isExposing, isTrue);

    await applyRemoteSyncEvent(
      container,
      imagingEvent('ExposureComplete', const {}),
      networkBackend: backend,
    );
    expect(container.read(cameraStateProvider).isExposing, isFalse);
  });

  test(
    'exposure events are IGNORED on the host path (no network backend)',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      await applyRemoteSyncEvent(
        container,
        imagingEvent('ExposureProgress', {
          'progress': 0.5,
          'remainingSecs': 30.0,
        }),
        // No networkBackend => host path; ImagingService already owns this state,
        // so the mirror must NOT run (would double-apply).
      );

      expect(container.read(cameraStateProvider).isExposing, isFalse);
    },
  );
}
