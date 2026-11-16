// A light that auto-calibration cannot calibrate is kept as captured, and
// the operator is told why once per cause. A loop that hits the same cause on
// every frame used to raise the same short-lived toast for each one, its
// reason cut off, and left nothing on screen once the toasts were gone.

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/clock_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/science/science_processing_service.dart';

import '../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';
import 'package:skotiq_core/src/providers/capture_preview_loader_provider.dart';
import 'package:skotiq_core/src/providers/imaging_service_providers.dart';
import 'package:skotiq_core/src/providers/science/science_processing_service_provider.dart';
import 'package:skotiq_core/src/providers/calibration_service_providers.dart';
import 'package:skotiq_core/src/providers/notification_service_provider.dart';
import 'package:skotiq_core/src/services/calibration_service.dart';
import 'package:skotiq_core/src/services/notification_service.dart';

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

/// Calibration that fails with [failure] while it is set, else succeeds.
class _ScriptedCalibration extends CalibrationService {
  _ScriptedCalibration(super.ref);

  static String? failure;

  @override
  Future<CalibrationResult> calibrateFile({
    required String lightPath,
    required CalibrationSettings settings,
    String? outputPath,
    double? exposureTime,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    double? sensorTemperature,
  }) async {
    final reason = failure;
    if (reason != null) throw StateError(reason);
    return CalibrationResult(
      outputPath: lightPath,
      darkApplied: true,
      flatApplied: false,
      biasApplied: true,
    );
  }
}

class _RecordingNotifications extends NotificationService {
  _RecordingNotifications(this.titles)
    : super(readSettings: () => null, readRouter: () => null);

  final List<String> titles;

  @override
  Future<NotificationDispatch> notifyError({
    required String errorTitle,
    required String errorMessage,
    String? source,
  }) async {
    titles.add('$errorTitle: $errorMessage');
    return const NotificationDispatch.refused('recorded by the test');
  }
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
  late SkotiqDatabase database;
  late List<String> writtenPaths;
  late List<String> notices;

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
    outputDir = Directory.systemTemp.createTempSync('sk_keeper_numbering');
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    writtenPaths = <String>[];
    notices = <String>[];
    _ScriptedCalibration.failure = null;
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
        keepCameraFile: any(named: 'keepCameraFile'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.namedArguments[#filePath] as String;
      writtenPaths.add(path);
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
      writtenPaths.add(path);
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const <int>[0]);
      return path;
    });
  });

  tearDown(() async {
    await database.close();
    unawaited(events.close());
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
        // A rebuilt service is a second container beside the first. They
        // share this one connection, as a restarted app shares one database;
        // two connections to one file in a process lock each other out.
        databaseProvider.overrideWithValue(database),
        clockProvider.overrideWithValue(const _FixedClock()),
        capturePreviewPublisherProvider.overrideWithValue(
          _NoOpCapturePreviewPublisher(),
        ),
        scienceProcessingServiceProvider.overrideWith(
          (ref) => _NoOpScienceProcessingService(ref),
        ),
        allSettingsProvider.overrideWith(
          (ref) => Stream.value({'calibration.auto_calibrate': 'true'}),
        ),
        calibrationServiceProvider.overrideWith(_ScriptedCalibration.new),
        notificationServiceProvider.overrideWithValue(
          _RecordingNotifications(notices),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(allSettingsProvider.future);
    expect(container.read(calibrationSettingsProvider).autoCalibrate, isTrue);
    return container;
  }

  const noBias =
      'the dark is 60 s and the light 2 s; a dark of another exposure can '
      'only be scaled with a master bias';

  test(
    'the operator is told once per cause, and every frame is counted',
    () async {
      final container = await buildContainer();
      final service = container.read(imagingServiceProvider);

      _ScriptedCalibration.failure = noBias;
      for (var i = 0; i < 3; i++) {
        await service.captureImage(settings: _settings);
      }

      expect(notices, hasLength(1), reason: notices.join('\n'));
      expect(notices.single, contains('Frames kept uncalibrated'));
      expect(notices.single, contains('can only be scaled with a master bias'));
      final notice = container.read(autoCalibrationNoticeProvider);
      expect(notice?.frames, 3);
      expect(notice?.reason, contains('can only be scaled with a master bias'));
    },
  );

  test(
    'a new cause, or the same one after a calibrated frame, is told again',
    () async {
      final container = await buildContainer();
      final service = container.read(imagingServiceProvider);

      _ScriptedCalibration.failure = noBias;
      await service.captureImage(settings: _settings);
      _ScriptedCalibration.failure = 'failed to read dark master';
      await service.captureImage(settings: _settings);
      expect(notices, hasLength(2));

      _ScriptedCalibration.failure = null;
      await service.captureImage(settings: _settings);
      expect(container.read(autoCalibrationNoticeProvider), isNull);

      _ScriptedCalibration.failure = noBias;
      await service.captureImage(settings: _settings);
      expect(notices, hasLength(3));
    },
  );

  test('a closed notice stays closed while its cause lasts', () async {
    final container = await buildContainer();
    final service = container.read(imagingServiceProvider);

    _ScriptedCalibration.failure = noBias;
    await service.captureImage(settings: _settings);
    container.read(autoCalibrationNoticeProvider.notifier).dismiss();
    await service.captureImage(settings: _settings);

    final notice = container.read(autoCalibrationNoticeProvider);
    expect(notice?.dismissed, isTrue);
    expect(notice?.frames, 2);
    expect(notices, hasLength(1));
  });
}
