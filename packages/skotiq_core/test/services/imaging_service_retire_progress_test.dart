// Losing the host mid-exposure must not leave the app narrating an exposure
// that will never finish.
//
// `imagingServiceProvider` watches `backendProvider`, so a host switch — or a
// remote client dropping back to DisconnectedBackend when the network goes —
// disposes the service and calls `retire()` while a frame is in flight. From
// that moment the retired service refuses to publish anything (correct: it must
// not write into the replacement host's provider graph), but it had already set
// `cameraStateProvider.isExposing = true` and pushed an `ExposureProgress`, and
// nothing else clears either. The exposure ring froze mid-count and the camera
// panel kept claiming an exposure was running, forever.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';

import '../mocks/mock_backend.dart';

/// Lets the test swap the active backend the way a host switch does.
class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void swapTo(SkotiqBackend backend) => state = backend;
}

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.getCameraCapabilities(any()),
    ).thenAnswer((_) async => null);
    when(() => backend.cameraAbortExposure(any())).thenAnswer((_) async {});
    // A driver (or host route) that starts the exposure and returns, leaving
    // the completion event to arrive later — which here it never does, because
    // the host goes away first.
    when(
      () => backend.cameraStartExposure(
        deviceId: any(named: 'deviceId'),
        exposureTime: any(named: 'exposureTime'),
        frameType: any(named: 'frameType'),
        gain: any(named: 'gain'),
        offset: any(named: 'offset'),
        binX: any(named: 'binX'),
        binY: any(named: 'binY'),
      ),
    ).thenAnswer((_) async {
      events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureProgress',
          data: const {'progress': 0.42, 'remainingSecs': 174.0},
        ),
      );
    });
  });

  tearDown(() => events.close());

  test('retiring mid-exposure clears the exposure it was narrating', () async {
    late _SwappableBackendNotifier backends;
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith((ref) {
          backends = _SwappableBackendNotifier(ref, backend);
          return backends;
        }),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting('cam-1', 'Test Camera');
          notifier.setConnected();
          return notifier;
        }),
      ],
    );
    addTearDown(container.dispose);
    // Keep the service element eager so the dependency change rebuilds it
    // (and runs its onDispose) instead of waiting for the next read.
    container.listen(imagingServiceProvider, (_, _) {});

    final capture = container
        .read(imagingServiceProvider)
        .captureImage(
          settings: const ExposureSettings(
            exposureTime: 300,
            gain: 100,
            offset: 10,
          ),
        );

    // Wait until the frame is genuinely in flight.
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(Duration.zero);
      if (container.read(exposureProgressProvider).percent > 0) break;
    }
    expect(
      container.read(cameraStateProvider).isExposing,
      isTrue,
      reason: 'precondition: the exposure is running',
    );

    // The host goes away.
    backends.swapTo(MockBackend());
    await capture;
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(exposureProgressProvider),
      ExposureProgress.idle(),
      reason: 'no host is going to finish this frame',
    );
    expect(
      container.read(cameraStateProvider).isExposing,
      isFalse,
      reason: 'the camera panel must not keep claiming an exposure is running',
    );
  });
}
