// `$SEQ` numbers the frames the operator KEEPS.
//
// Live-view (Loop) and utility (centering/plate-solve) exposures go to one
// reused scratch file and are never indexed, but they still moved the same
// counter the naming pattern renders: after a 3-frame framing loop the next
// Snapshot was written as _0004 with only two keepers on disk, and after a
// 30-minute loop it was numbered in the hundreds. A short loop is worse than
// cosmetic — it pushes the counter BACKWARDS onto a number already on disk, so
// the next keeper collides and lands as `..._0003_001.fits`.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
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

const _settings = ExposureSettings(exposureTime: 1, gain: 100, offset: 10);

/// Pinned to the instant the mock camera reports, so `$DATE` in the naming
/// pattern renders the same day whether it is resolved from the host clock
/// (before the exposure) or from the camera's own timestamp (after it) — the
/// relationship a real camera has with the host clock.
class _FixedClock implements Clock {
  const _FixedClock();

  @override
  DateTime now() => DateTime.utc(2026, 1, 15, 22, 30);

  @override
  DateTime nowUtc() => DateTime.utc(2026, 1, 15, 22, 30);

  @override
  Duration get utcOffset => Duration.zero;

  @override
  DateTime fromUtc(DateTime utc) => utc;
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
    outputDir = Directory.systemTemp.createTempSync('ns_keeper_numbering');
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
      File(path).writeAsBytesSync(const <int>[0]);
    });
  });

  tearDown(() {
    events.close();
    if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
  });

  Future<ProviderContainer> buildContainer() async {
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
            // The shipped default pattern: the trailing $SEQ is the counter
            // under test.
            AppSettingsState(imageOutputPath: outputDir.path),
          ),
        ),
        clockProvider.overrideWithValue(const _FixedClock()),
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

  /// The `$SEQ` token of each frame that landed in the operator's folder.
  List<String> keeperSequenceNumbers() => writtenPaths
      .where((path) => p.isWithin(outputDir.path, path))
      .map((path) => p.basenameWithoutExtension(path).split('_').last)
      .toList();

  test('a framing loop does not renumber the operator\'s keepers', () async {
    final container = await buildContainer();
    final service = container.read(imagingServiceProvider);

    await service.captureImage(settings: _settings);
    await service.captureImage(settings: _settings);
    await service.startLoopCapture(settings: _settings, maxFrames: 3);
    await service.captureImage(settings: _settings);

    expect(
      keeperSequenceNumbers(),
      ['0001', '0002', '0003'],
      reason: 'three keepers were saved, so they are frames 1, 2 and 3',
    );
  });

  test('utility (plate-solve) frames do not renumber keepers', () async {
    final container = await buildContainer();
    final service = container.read(imagingServiceProvider);

    await service.captureImage(settings: _settings);
    // What a centering run does between subs.
    await service.captureUtilityFrame(
      settings: _settings,
      targetName: 'Centering',
    );
    await service.captureUtilityFrame(
      settings: _settings,
      targetName: 'Verification',
    );
    await service.captureImage(settings: _settings);

    expect(keeperSequenceNumbers(), ['0001', '0002']);
  });

  test(
    'a second saving loop continues the numbering, not restarts it',
    () async {
      final container = await buildContainer();
      final service = container.read(imagingServiceProvider);

      await service.startLoopCapture(
        settings: _settings,
        maxFrames: 2,
        saveFrames: true,
      );
      await service.startLoopCapture(
        settings: _settings,
        maxFrames: 2,
        saveFrames: true,
      );

      expect(
        keeperSequenceNumbers(),
        ['0001', '0002', '0003', '0004'],
        reason:
            'restarting at 1 collides with the first run and yields _001 '
            'suffixes instead of sequence numbers',
      );
      expect(
        writtenPaths.where((path) => path.contains('_001.')),
        isEmpty,
        reason: 'no collision-uniquifier suffix should be needed',
      );
    },
  );

  test('an explicit frame number from the caller still wins', () async {
    final container = await buildContainer();
    final service = container.read(imagingServiceProvider);

    await service.captureImage(settings: _settings, frameNumber: 7);
    await service.captureImage(settings: _settings);

    expect(keeperSequenceNumbers(), ['0007', '0008']);
  });

  // `imagingServiceProvider` watches `backendProvider`, so the counter resets
  // to 0 on every app start AND on every host switch/reconnect — several times
  // a night, not once.
  test('a rebuilt service continues the numbering already on disk', () async {
    final first = await buildContainer();
    await first.read(imagingServiceProvider).captureImage(settings: _settings);
    await first.read(imagingServiceProvider).captureImage(settings: _settings);

    final second = await buildContainer();
    await second.read(imagingServiceProvider).captureImage(settings: _settings);

    expect(
      keeperSequenceNumbers(),
      ['0001', '0002', '0003'],
      reason: 'the third keeper is the third frame in the folder',
    );
    expect(
      writtenPaths.where((path) => path.contains('_001.')),
      isEmpty,
      reason: 'a restart must not need the collision uniquifier',
    );
  });

  test('numbering restarts when the folder is empty again', () async {
    final first = await buildContainer();
    await first.read(imagingServiceProvider).captureImage(settings: _settings);
    for (final file in outputDir.listSync()) {
      file.deleteSync();
    }

    final second = await buildContainer();
    await second.read(imagingServiceProvider).captureImage(settings: _settings);

    expect(
      keeperSequenceNumbers().last,
      '0001',
      reason: 'probing must follow the folder, not a high-water mark',
    );
  });
}
