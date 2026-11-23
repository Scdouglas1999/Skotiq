// A manual frame leaves the exposure progress idle when it ends.
//
// `exposureProgressProvider` is shared by the capture service, the remote
// mirror and every screen that draws an exposure ring. A frame that ended
// without putting it back to idle left Tonight's frame showing the last
// countdown, or "downloading", until the next capture.

import 'dart:async';
import 'dart:io';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/clock_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';

import '../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';
import 'package:skotiq_core/src/providers/capture_preview_loader_provider.dart';
import 'package:skotiq_core/src/providers/imaging_service_providers.dart';
import 'package:skotiq_core/src/providers/science/science_processing_service_provider.dart';
import '../harness/event_wire.dart';
import '../harness/imaging_event_rows.dart';

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
  late void Function() onExposureStarted;

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
    onExposureStarted = () => events.add(
      ffiWireEvent(
        const bridge.EventPayload.imaging(
          bridge.ImagingEvent.exposureComplete(success: true),
        ),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
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
      onExposureStarted();
    });
    when(
      () => backend.cameraGetLastImage(any()),
    ).thenAnswer((_) async => _unparseableTimestampImage());
    when(
      () => backend.saveFitsFromLastCapture(
        deviceId: any(named: 'deviceId'),
        filePath: any(named: 'filePath'),
        headerData: any(named: 'headerData'),
        keepCameraFile: any(named: 'keepCameraFile'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.namedArguments[#filePath] as String;
      File(path).writeAsBytesSync(const <int>[0]);
      return invocation.namedArguments[#filePath] as String;
    });
    when(
      () => backend.saveScratchFrameFromLastCapture(
        deviceId: any(named: 'deviceId'),
        name: any(named: 'name'),
        headerData: any(named: 'headerData'),
      ),
    ).thenAnswer((invocation) async {
      final path =
          '${Directory.systemTemp.path}/skotiq_captures/${invocation.namedArguments[#name]}';
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const <int>[0]);
      return path;
    });
  });

  tearDown(() async {
    await events.close();
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
  });

  Future<ProviderContainer> buildContainer(Clock clock) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
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
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
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

  // Which events end a capture's wait for its exposure and how, over both
  // transports. A row that does not end the wait is ended by a completion
  // sent 200 ms later. Pinned on the capture pipeline's name compares.
  test('the events that end a capture\'s exposure wait', () async {
    final container = await buildContainer(const SystemClock());
    final service = container.read(imagingServiceProvider);

    Future<String> outcomeOf(SkotiqEvent event) async {
      var fallbackSent = false;
      onExposureStarted = () {
        events.add(event);
        Timer(const Duration(milliseconds: 200), () {
          fallbackSent = true;
          events.add(
            ffiWireEvent(
              const bridge.EventPayload.imaging(
                bridge.ImagingEvent.exposureComplete(success: true),
              ),
            ),
          );
        });
      };
      final progress = <double>[];
      final sub = container.listen(
        exposureProgressProvider,
        (_, next) => progress.add(next.percent),
      );
      String outcome;
      try {
        final image = await service.captureUtilityFrame(settings: _settings);
        outcome = image == null ? 'none' : 'frame';
      } catch (e) {
        outcome = 'error(${e.toString().replaceAll('Exception: ', '')})';
      }
      sub.close();
      final when = fallbackSent ? 'after the fallback' : 'at once';
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final halfway = progress.contains(50.0) ? ' progress=50' : '';
      return '$outcome $when$halfway';
    }

    final table = <String, String>{};
    for (final row in imagingEventRows.entries) {
      final ffi = await outcomeOf(ffiWireEvent(row.value));
      final network = await outcomeOf(networkWireEvent(row.value));
      expect(network, ffi, reason: '${row.key}: the transports disagree');
      table[row.key] = ffi;
    }
    expect(table, <String, String>{
      'exposureStarted': 'frame after the fallback',
      'exposureStartedWithFrame': 'frame after the fallback',
      'exposureProgress': 'frame after the fallback progress=50',
      'exposureCompleted': 'frame after the fallback',
      'exposureCompletedWithFrame': 'frame after the fallback',
      'exposureFailed': 'error(Exposure failed: timeout) at once',
      'exposureFailedOld': 'error(Exposure failed: Unknown error) at once',
      'exposureCancelled': 'none at once',
      'downloadStarted': 'frame after the fallback',
      'downloadCompleted': 'frame after the fallback',
      'imageReady': 'frame after the fallback',
      'imageSaved': 'frame after the fallback',
      'integrationProgress': 'frame after the fallback',
      'integrationTelemetry': 'frame after the fallback',
      'temperatureChanged': 'frame after the fallback',
      'exposureComplete ok': 'frame at once',
      'exposureComplete failed': 'frame at once',
      'depthLock goalChanged': 'frame after the fallback',
      'sequencer ExposureCompleted': 'frame after the fallback',
    });
  });
}
