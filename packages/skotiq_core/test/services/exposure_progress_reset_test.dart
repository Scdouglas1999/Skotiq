// A manual frame leaves the exposure progress idle when it ends.
//
// `exposureProgressProvider` is shared by the capture service, the remote
// mirror and every screen that draws an exposure ring. A frame that ended
// without putting it back to idle left Tonight's frame showing the last
// countdown, or "downloading", until the next capture.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/clock_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
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
  void publish(dynamic ref, CapturedImageData preview, String deviceId) {}
}

class _FakeAppSettings extends AppSettingsNotifier {
  _FakeAppSettings(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// The camera reports a timestamp the app cannot parse, which is the branch
/// that falls back to the app's own clock.
CapturedImageResult _unparseableTimestampImage() {
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
    timestamp: 'sensor said nothing useful',
    exposureTime: 5.0,
  );
}

const _settings = ExposureSettings(exposureTime: 1, gain: 100, offset: 10);

void main() {
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;
  late Directory outputDir;

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
    outputDir = Directory.systemTemp.createTempSync('sk_progress_reset');
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
    ).thenAnswer((_) async => _unparseableTimestampImage());
    when(
      () => backend.saveFitsFromLastCapture(
        deviceId: any(named: 'deviceId'),
        filePath: any(named: 'filePath'),
        headerData: any(named: 'headerData'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.namedArguments[#filePath] as String;
      File(path).writeAsBytesSync(const <int>[0]);
    });
  });

  tearDown(() {
    events.close();
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
  });

  Future<ProviderContainer> buildContainer(Clock clock) async {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier.setConnecting('cam-1', 'Test Camera');
          notifier.setConnected();
          return notifier;
        }),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettings(
            AppSettingsState(imageOutputPath: outputDir.path),
          ),
        ),
        clockProvider.overrideWithValue(clock),
        capturePreviewPublisherProvider.overrideWithValue(
          _NoOpCapturePreviewPublisher(),
        ),
        scienceProcessingServiceProvider.overrideWith(
          (ref) => _NoOpScienceProcessingService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    return container;
  }

  for (final persisted in <bool>[true, false]) {
    test('a ${persisted ? 'saved' : 'utility'} frame ends idle', () async {
      final container = await buildContainer(const SystemClock());
      final service = container.read(imagingServiceProvider);
      final seen = <ExposureProgress>[];
      container.listen(exposureProgressProvider, (_, next) => seen.add(next));

      final captured = persisted
          ? await service.captureImage(settings: _settings)
          : await service.captureUtilityFrame(settings: _settings);

      expect(captured, isNotNull, reason: 'non-vacuous: the frame came back');
      expect(
        seen.any((p) => p.isDownloading),
        isTrue,
        reason: 'non-vacuous: the frame went through the download state',
      );
      expect(container.read(exposureProgressProvider), ExposureProgress.idle());
      expect(container.read(cameraStateProvider).isExposing, isFalse);
    });
  }

  test('a failed download ends idle', () async {
    when(
      () => backend.cameraGetLastImage(any()),
    ).thenThrow(Exception('USB went away'));
    final container = await buildContainer(const SystemClock());

    await expectLater(
      container.read(imagingServiceProvider).captureImage(settings: _settings),
      throwsA(anything),
    );
    expect(container.read(exposureProgressProvider), ExposureProgress.idle());
  });
}
