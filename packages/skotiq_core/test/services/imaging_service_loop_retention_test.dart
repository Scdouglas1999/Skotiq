// Loop is a live-view mode, not an acquisition run.
//
// Routing it through the acquisition path writes every looped frame full-size
// into the operator's light-frame folder and indexes it in `captured_images` —
// ~27 GB of `Unknown_NoFilter_*` lights per hour of framing. These tests pin
// the destination of a loop frame to a reused scratch path, and pin that the
// opt-in still works.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
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
  late Directory outputDir;
  late List<String> writtenPaths;

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
    outputDir = Directory.systemTemp.createTempSync('ns_loop_retention');
    writtenPaths = <String>[];
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
    ).thenAnswer((invocation) async {
      final path = invocation.namedArguments[#filePath] as String;
      writtenPaths.add(path);
      // The real Rust save leaves a file behind; the DB insert path stats it.
      File(path).writeAsBytesSync(const <int>[0]);
    });
  });

  tearDown(() {
    events.close();
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
  });

  ProviderContainer buildContainer() {
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
        // A configured light-frame folder is what makes this defect visible:
        // without one every frame already went to temp.
        appSettingsProvider.overrideWith(
          () => _FakeAppSettings(
            AppSettingsState(imageOutputPath: outputDir.path),
          ),
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

  Future<void> settleSettings(ProviderContainer container) async {
    await container.read(appSettingsProvider.future);
  }

  test(
    'a loop run writes no frames into the configured image folder',
    () async {
      final container = buildContainer();
      await settleSettings(container);

      await container
          .read(imagingServiceProvider)
          .startLoopCapture(
            settings: const ExposureSettings(
              exposureTime: 1,
              gain: 100,
              offset: 10,
            ),
            maxFrames: 3,
          );

      expect(writtenPaths, hasLength(3));
      expect(
        writtenPaths.where((path) => p.isWithin(outputDir.path, path)),
        isEmpty,
        reason: 'live-view frames must never land in the light-frame folder',
      );
      // One reused scratch file, not three accumulating 23 MB lights.
      expect(writtenPaths.toSet(), hasLength(1));
      expect(p.basename(writtenPaths.first), startsWith('liveview_'));
      expect(outputDir.listSync(recursive: true), isEmpty);
    },
  );

  test('Loop still exposes after a cancel — the latch is not sticky', () async {
    final container = buildContainer();
    await settleSettings(container);
    final service = container.read(imagingServiceProvider);

    // Stop Loop / Abort both call this. It latches `_cancelRequested`, and the
    // ONLY place that clears it is inside `_capture` — which the loop reaches
    // after testing the flag, so a latch left set makes the next Loop press
    // start and end without ever exposing: a dead button, no error, nothing
    // logged.
    service.cancelExposure();

    await service.startLoopCapture(
      settings: const ExposureSettings(exposureTime: 1, gain: 100, offset: 10),
      maxFrames: 2,
    );

    expect(
      writtenPaths,
      hasLength(2),
      reason:
          'a cancel of the PREVIOUS run must not silently kill the next one',
    );
  });

  test('opting in sends loop frames to the configured image folder', () async {
    final container = buildContainer();
    await settleSettings(container);

    await container
        .read(imagingServiceProvider)
        .startLoopCapture(
          settings: const ExposureSettings(
            exposureTime: 1,
            gain: 100,
            offset: 10,
          ),
          maxFrames: 2,
          saveFrames: true,
        );

    expect(writtenPaths, hasLength(2));
    expect(
      writtenPaths.every((path) => p.isWithin(outputDir.path, path)),
      isTrue,
      reason: 'an explicit opt-in must keep behaving like Snapshot',
    );
    expect(writtenPaths.toSet(), hasLength(2));
  });

  test('a single Snapshot still goes to the image folder', () async {
    final container = buildContainer();
    await settleSettings(container);

    await container
        .read(imagingServiceProvider)
        .captureImage(
          settings: const ExposureSettings(
            exposureTime: 1,
            gain: 100,
            offset: 10,
          ),
        );

    expect(writtenPaths, hasLength(1));
    expect(p.isWithin(outputDir.path, writtenPaths.single), isTrue);
  });
}
