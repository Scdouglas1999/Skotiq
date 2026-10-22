// Every frame this service writes must name the filter the light actually
// passed through.
//
// [ExposureSettings] is a UI mirror and is not authoritative: a screen that
// does not write its filter selection back into it produces frames with no FITS
// FILTER card, a "NoFilter" filename and an empty `captured_images.filter`
// while displaying the active filter. These tests pin the resolution to the
// live wheel.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';

import '../mocks/mock_backend.dart';

class _NoOpScienceProcessingService extends ScienceProcessingService {
  _NoOpScienceProcessingService(super.ref);

  @override
  Future<void> processCapturedFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
  }) async {}
}

class _NoOpCapturePreviewPublisher extends CapturePreviewPublisher {
  @override
  void publish(
    dynamic ref,
    CapturedImageData preview,
    String deviceId, {
    bool loadRaw = true,
  }) {}
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// A filter wheel parked on a known slot, without any driver round-trip.
class _SeededFilterWheel extends FilterWheelStateNotifier {
  _SeededFilterWheel(super.ref, FilterWheelState seed) {
    state = seed;
  }
}

CapturedImageResult _capturedImage() {
  return CapturedImageResult(
    width: 8,
    height: 8,
    displayData: List<int>.filled(8 * 8 * 4, 128),
    histogram: List<int>.filled(256, 1),
    stats: const ImageStatsResult(
      min: 100.0,
      max: 20000.0,
      mean: 5000.0,
      median: 4800.0,
      stdDev: 500.0,
      hfr: 2.5,
      starCount: 80,
    ),
    timestamp: '2026-01-15T22:30:00Z',
    exposureTime: 5.0,
  );
}

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;

  setUpAll(() {
    registerMocktailFallbackValues();
    registerFallbackValue(
      const FitsWriteHeader(
        exposureTime: 1.0,
        captureTimestamp: '2026-01-01T00:00:00Z',
        frameType: 'Light',
      ),
    );
  });

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
    when(
      () => backend.cameraSetReadoutMode(any(), any()),
    ).thenAnswer((_) async {});
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
          eventType: 'ExposureComplete',
          data: const {},
        ),
      );
    });
    when(
      () => backend.cameraGetLastImage(any()),
    ).thenAnswer((_) async => _capturedImage());
    when(
      () => backend.saveFitsFromLastCapture(
        deviceId: any(named: 'deviceId'),
        filePath: any(named: 'filePath'),
        headerData: any(named: 'headerData'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() => events.close());

  ProviderContainer containerWith(FilterWheelState? wheel) {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting('test-camera-1', 'Test Camera');
          notifier.setConnected();
          return notifier;
        }),
        if (wheel != null)
          filterWheelStateProvider.overrideWith(
            (ref) => _SeededFilterWheel(ref, wheel),
          ),
        capturePreviewPublisherProvider.overrideWithValue(
          _NoOpCapturePreviewPublisher(),
        ),
        scienceProcessingServiceProvider.overrideWith(
          (ref) => _NoOpScienceProcessingService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<FitsWriteHeader> captureHeader(
    ProviderContainer container,
    ExposureSettings settings,
  ) async {
    final result = await container
        .read(imagingServiceProvider)
        .captureImage(settings: settings);
    expect(result, isNotNull);
    return verify(
          () => backend.saveFitsFromLastCapture(
            deviceId: any(named: 'deviceId'),
            filePath: any(named: 'filePath'),
            headerData: captureAny(named: 'headerData'),
          ),
        ).captured.single
        as FitsWriteHeader;
  }

  const connectedHa = FilterWheelState(
    connectionState: DeviceConnectionState.connected,
    deviceId: 'sim_filterwheel_1',
    deviceName: 'Simulated Filter Wheel',
    currentPosition: 4,
    filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
  );

  test(
    'FITS FILTER names the connected wheel slot even when the caller left it null',
    () async {
      final container = containerWith(connectedHa);
      final header = await captureHeader(
        container,
        const ExposureSettings(exposureTime: 1, gain: 100, offset: 10),
      );
      expect(header.filter, 'Ha');
    },
  );

  test(
    'a stale settings filter loses to the wheel the light went through',
    () async {
      final container = containerWith(connectedHa);
      final header = await captureHeader(
        container,
        const ExposureSettings(
          exposureTime: 1,
          gain: 100,
          offset: 10,
          filter: 'L',
        ),
      );
      expect(header.filter, 'Ha');
    },
  );

  test(
    'the session image records the resolved filter, not the caller copy',
    () async {
      final container = containerWith(connectedHa);
      await container
          .read(imagingServiceProvider)
          .captureImage(
            settings: const ExposureSettings(
              exposureTime: 1,
              gain: 100,
              offset: 10,
            ),
          );
      final sessionImages = container.read(sessionImagesProvider);
      expect(sessionImages, hasLength(1));
      expect(sessionImages.single.settings.filter, 'Ha');
    },
  );

  test(
    'a disconnected wheel leaves the caller-supplied filter alone',
    () async {
      final container = containerWith(
        const FilterWheelState(
          connectionState: DeviceConnectionState.disconnected,
          currentPosition: 4,
          filterNames: ['L', 'R', 'G', 'B', 'Ha'],
        ),
      );
      final header = await captureHeader(
        container,
        const ExposureSettings(
          exposureTime: 1,
          gain: 100,
          offset: 10,
          filter: 'Sequencer Ha',
        ),
      );
      expect(header.filter, 'Sequencer Ha');
    },
  );

  test(
    'a connected wheel that cannot name its slot keeps the caller value',
    () async {
      final container = containerWith(
        const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'wheel',
          // Position outside the reported names: currentFilterName is null.
          currentPosition: 9,
          filterNames: ['L', 'R'],
        ),
      );
      final header = await captureHeader(
        container,
        const ExposureSettings(
          exposureTime: 1,
          gain: 100,
          offset: 10,
          filter: 'L',
        ),
      );
      expect(header.filter, 'L');
    },
  );
}
