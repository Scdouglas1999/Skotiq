// Provider-level tests that the ONE effective capture config resolved at run
// start actually flows into the backend command AND the FITS header, and that
// asynchronous capability loading never clobbers a user's explicit target.
//
// Pins the trust-hardening contract end-to-end through `runCapture`:
//   * A 12-bit camera targets its DETECTED 4095 range (published for the UI).
//   * An unsupported gain is NEVER commanded (null == camera default), and the
//     FITS header records that truthfully.
//   * Profile binning flows to both the capture command and the FITS header.
//   * A late capability load does not rewrite the user's explicit target %.
//   * A cancel saves/counts NOTHING and aborts the hardware exactly once.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_database.dart';

const String _cam = 'native:cam:0';

CameraStatus _status({
  int maxAdu = 65535,
  int gain = 50,
  int offset = 8,
  bool canSetGain = true,
  bool canSetOffset = true,
}) => CameraStatus.fromJson({
  'connected': true,
  'gain': gain,
  'offset': offset,
  'binX': 1,
  'binY': 1,
  'maxAdu': maxAdu,
  'canSetGain': canSetGain,
  'canSetOffset': canSetOffset,
});

CameraCapabilities _caps({
  int bitDepth = 16,
  bool canSetGain = true,
  bool canSetOffset = true,
  bool canBin = true,
  int maxBinX = 4,
  int maxBinY = 4,
  bool canAsymmetricBin = true,
}) => CameraCapabilities.fromJson({
  'maxWidth': 1000,
  'maxHeight': 1000,
  'bitDepth': bitDepth,
  'canSetGain': canSetGain,
  'canSetOffset': canSetOffset,
  'canBin': canBin,
  'maxBinX': maxBinX,
  'maxBinY': maxBinY,
  'canAsymmetricBin': canAsymmetricBin,
});

CapturedImageResult _image(double mean) => CapturedImageResult(
  width: 4,
  height: 4,
  displayData: List<int>.filled(4 * 4 * 4, 128),
  histogram: List<int>.filled(256, 1),
  stats: ImageStatsResult(
    min: mean * 0.9,
    max: mean * 1.1,
    mean: mean,
    median: mean,
    stdDev: mean * 0.05,
    starCount: 0,
  ),
  exposureTime: 1.0,
  timestamp: DateTime.now().toUtc().toIso8601String(),
);

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _SeededCameraNotifier extends CameraStateNotifier {
  _SeededCameraNotifier(super.ref, CameraStateSnapshot seed) {
    state = seed;
  }

  void set(CameraStateSnapshot next) => state = next;
}

class _SeededFilterWheelNotifier extends FilterWheelStateNotifier {
  _SeededFilterWheelNotifier(super.ref, List<String> names) {
    state = FilterWheelState(filterNames: names);
  }
}

/// Auto-completing camera that also serves capability probes and records the
/// gain/offset/binning it is COMMANDED with, plus every FITS header written.
class _CapAutoBackend extends Mock implements SkotiqBackend {
  _CapAutoBackend({
    required this.status,
    required this.caps,
    required this.imageMean,
  });

  final CameraStatus status;
  final CameraCapabilities caps;
  final double imageMean;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final List<Map<String, Object?>> startParams = [];
  final List<FitsWriteHeader> headers = [];
  int _seq = 0;

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async => status;

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      caps;

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    startParams.add({
      'gain': gain,
      'offset': offset,
      'binX': binX,
      'binY': binY,
    });
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(
        SkotiqEvent(
          timestamp: ++_seq,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureCompleted',
          data: {'deviceId': deviceId},
        ),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async =>
      _image(imageMean);

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    headers.add(headerData);
  }
}

/// Gated camera for cancel/unknown-range tests: exposures never auto-complete;
/// the abort emits ExposureCancelled. The status probe can be disabled to
/// prove automatic calibration fails closed when no ADU range is known.
class _GatedBackend extends Mock implements SkotiqBackend {
  _GatedBackend({this.statusAvailable = true});

  final bool statusAvailable;
  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  int startCount = 0;
  int saveCount = 0;
  final Completer<void> firstExposureStarted = Completer<void>();
  final List<String> abortCalls = [];
  int _seq = 0;

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    if (!statusAvailable) throw StateError('no status');
    return _status();
  }

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      throw StateError('no caps');

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    startCount++;
    if (!firstExposureStarted.isCompleted) firstExposureStarted.complete();
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    abortCalls.add(deviceId);
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(
        SkotiqEvent(
          timestamp: ++_seq,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureCancelled',
          data: {'deviceId': deviceId},
        ),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async =>
      _image(32768);

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    saveCount++;
  }
}

class _DelayedProbeBackend extends Mock implements SkotiqBackend {
  final Completer<CameraStatus> oldStatus = Completer<CameraStatus>();
  final Completer<void> oldRequested = Completer<void>();

  @override
  Stream<SkotiqEvent> get eventStream => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) {
    if (deviceId == _cam) {
      if (!oldRequested.isCompleted) oldRequested.complete();
      return oldStatus.future;
    }
    return Future.value(_status(maxAdu: 4095));
  }

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      _caps(bitDepth: deviceId == _cam ? 16 : 12);
}

Future<void> _pump([int times = 6]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late SkotiqDatabase db;
  late Directory tempDir;

  setUpAll(() {
    registerFallbackValue(FrameType.flat);
    registerFallbackValue(
      const FitsWriteHeader(
        frameType: 'FLAT',
        filter: 'X',
        exposureTime: 1,
        captureTimestamp: '',
      ),
    );
  });

  setUp(() {
    db = createTestDatabase();
    tempDir = Directory.systemTemp.createTempSync('flatwiz_config');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(
    SkotiqBackend backend, {
    EquipmentProfileModel? profile,
    List<String> filterNames = const ['L'],
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        activeEquipmentProfileProvider.overrideWithValue(profile),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith(
          (ref) => _SeededCameraNotifier(
            ref,
            const CameraStateSnapshot(
              connectionState: DeviceConnectionState.connected,
              deviceId: _cam,
              gain: 50,
              offset: 8,
            ),
          ),
        ),
        filterWheelStateProvider.overrideWith(
          (ref) => _SeededFilterWheelNotifier(ref, filterNames),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<FlatWizardNotifier> primeWizard(
    ProviderContainer container, {
    int frameCount = 1,
    double? histogramTarget,
  }) async {
    final notifier = container.read(flatWizardProvider.notifier);
    await notifier.loadFiltersFromWheel();
    var gs = container
        .read(flatWizardProvider)
        .globalSettings
        .copyWith(
          savePath: tempDir.path,
          createDateSubfolder: false,
          createFilterSubfolders: false,
          frameCount: frameCount,
        );
    if (histogramTarget != null) {
      gs = gs.copyWith(histogramTarget: histogramTarget);
    }
    notifier.updateGlobalSettings(gs);
    notifier.setMode(FlatWizardMode.quick);
    notifier.setCurrentFilterIndex(0);
    return notifier;
  }

  test(
    '12-bit left-justified camera targets its container range, not 4095',
    () async {
      // An ASI1600MM-class sensor: 12-bit ADC, samples left-justified into the
      // 16-bit pixel word, so the driver reports 4095 << 4. The bit depth must
      // NOT cap the target — measured frame means are in container units, so a
      // 4095-scaled target could never be reached.
      final backend = _CapAutoBackend(
        status: _status(maxAdu: 65520),
        caps: _caps(bitDepth: 12),
        imageMean: 32760, // on target for 50% of 65520
      );
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = await primeWizard(container);

      await notifier.runCapture();
      await _pump();

      final cfg = container.read(flatCameraConfigProvider);
      expect(
        cfg.maxAdu,
        65520,
        reason: 'UI/preview sees the container range the pixels use',
      );
      expect(cfg.bitDepth, 12, reason: 'ADC precision is still reported');
      expect(
        container.read(flatWizardProvider).filterSettings[0].status,
        FilterCalibrationStatus.complete,
      );
    },
  );

  test(
    'an unsupported gain is never commanded and the FITS header is truthful',
    () async {
      final backend = _CapAutoBackend(
        status: _status(canSetGain: false),
        caps: _caps(canSetGain: false),
        imageMean: 32768,
      );
      addTearDown(backend.dispose);
      final container = makeContainer(
        backend,
        profile: const EquipmentProfileModel(
          name: 'T',
          defaultGain: 100, // present, but the camera can't set gain
          defaultOffset: 20,
        ),
      );
      final notifier = await primeWizard(container);

      await notifier.runCapture();

      // gain must be null on EVERY exposure (calibration + frames) and in the
      // saved FITS header — never a stale/forced numeric value.
      expect(backend.startParams, isNotEmpty);
      expect(
        backend.startParams.every((p) => p['gain'] == null),
        isTrue,
        reason: 'unsupported gain must never be sent',
      );
      expect(backend.headers, isNotEmpty);
      expect(backend.headers.every((h) => h.gain == null), isTrue);
      // offset IS settable → the profile default flows through.
      expect(backend.startParams.every((p) => p['offset'] == 20), isTrue);
      expect(container.read(flatCameraConfigProvider).canSetGain, isFalse);
    },
  );

  test('profile binning flows into the command AND the FITS header', () async {
    final backend = _CapAutoBackend(
      status: _status(),
      caps: _caps(maxBinX: 4, maxBinY: 4, canAsymmetricBin: true),
      imageMean: 32768,
    );
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      profile: const EquipmentProfileModel(
        name: 'T',
        defaultBinX: 2,
        defaultBinY: 2,
      ),
    );
    final notifier = await primeWizard(container);

    await notifier.runCapture();

    expect(backend.startParams, isNotEmpty);
    expect(
      backend.startParams.every((p) => p['binX'] == 2 && p['binY'] == 2),
      isTrue,
    );
    expect(backend.headers.single.binX, 2);
    expect(backend.headers.single.binY, 2);
  });

  test(
    'a late capability load does NOT clobber the user\'s explicit target',
    () async {
      final backend = _CapAutoBackend(
        status: _status(maxAdu: 65520),
        caps: _caps(bitDepth: 12),
        imageMean: 2000,
      );
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = container.read(flatWizardProvider.notifier);
      // User sets an explicit, valid target BEFORE capabilities are known.
      notifier.setHistogramTarget(70);

      // Capabilities load asynchronously (12-bit ADC, 16-bit container).
      await container.read(flatCameraConfigProvider.notifier).resolve();
      await _pump();

      // The user's percentage is preserved verbatim…
      expect(
        container.read(flatWizardProvider).globalSettings.histogramTarget,
        70,
      );
      // …and reads out against the detected container range (0.7 * 65520).
      final cfg = container.read(flatCameraConfigProvider);
      expect(cfg.maxAdu, 65520);
      expect(cfg.targetAduFor(70), closeTo(45864, 1));
    },
  );

  test(
    'a late old-camera probe cannot overwrite the new camera config',
    () async {
      final backend = _DelayedProbeBackend();
      final container = makeContainer(backend);
      container.read(flatCameraConfigProvider.notifier);
      await backend.oldRequested.future;

      final cameraNotifier =
          container.read(cameraStateProvider.notifier) as _SeededCameraNotifier;
      cameraNotifier.set(
        const CameraStateSnapshot(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'native:cam:1',
        ),
      );
      await _pump(10);
      expect(container.read(flatCameraConfigProvider).maxAdu, 4095);

      backend.oldStatus.complete(_status(maxAdu: 65535));
      await _pump(10);

      expect(
        container.read(flatCameraConfigProvider).maxAdu,
        4095,
        reason: 'the superseded camera probe must be ignored',
      );
    },
  );

  test(
    'a cancel saves/counts nothing and aborts the hardware exactly once',
    () async {
      final backend = _GatedBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = await primeWizard(container, frameCount: 3);

      // Start the run but do not await; let it reach the calibration exposure.
      final run = notifier.runCapture();
      try {
        // Configuration and output-directory preparation perform real async
        // I/O. A fixed number of event-loop turns cannot establish readiness.
        await backend.firstExposureStarted.future.timeout(
          const Duration(seconds: 5),
        );
        expect(backend.startCount, 1);
      } finally {
        // Drain the run even after a failed assertion, before provider teardown.
        notifier.requestCancel();
        await run.timeout(const Duration(seconds: 5));
      }

      expect(backend.saveCount, 0, reason: 'a cancelled run saves no frames');
      expect(
        container.read(flatWizardProvider).filterSettings[0].capturedCount,
        0,
      );
      expect(backend.abortCalls, hasLength(1), reason: 'abort issued once');
      final status =
          container.read(flatWizardProvider).statusMessage?.toLowerCase() ?? '';
      expect(status, contains('cancel'));
    },
  );

  test(
    'automatic capture fails closed when camera ADU range is unknown',
    () async {
      final backend = _GatedBackend(statusAvailable: false);
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = await primeWizard(container);

      await notifier.runCapture();

      final config = container.read(flatCameraConfigProvider);
      final state = container.read(flatWizardProvider);
      expect(config.rangeKnown, isFalse);
      expect(backend.startCount, 0, reason: 'no exposure uses guessed ADU');
      expect(state.isCapturing, isFalse);
      expect(state.errorMessage, contains('ADU range'));
      expect(state.statusMessage, contains('unknown'));
    },
  );
}
