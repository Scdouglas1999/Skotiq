// The flat wizard's settings panel stays editable while a run is in flight.
// A run must therefore capture against the settings it STARTED with: a mid-run
// edit that changed the per-filter frame target, or the histogram target the
// flat library learns from, would silently produce a run nobody asked for.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_database.dart';

// histogramPercentToAdu(50) == 32768 — the default target. Returning it makes
// the solver converge on iteration 1 regardless of tolerance.
const double _onTargetAdu = 32768;
const String _cam = 'native:cam:0';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _SeededCameraNotifier extends CameraStateNotifier {
  _SeededCameraNotifier(super.ref, CameraStateSnapshot seed) {
    state = seed;
  }
}

class _SeededFilterWheelNotifier extends FilterWheelStateNotifier {
  _SeededFilterWheelNotifier(super.ref, List<String> names) {
    state = FilterWheelState(filterNames: names);
  }
}

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

/// Auto-completing camera backend. [onSave] fires on each FITS write with the
/// 1-based attempt number, which is where these tests inject the mid-run edit.
class _AutoBackend extends Mock implements SkotiqBackend {
  _AutoBackend({this.onSave});

  final void Function(int attempt)? onSave;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final commands = <({int? gain, int? offset})>[];
  final savedHeaders = <FitsWriteHeader>[];
  int saveCount = 0;
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
  Future<CameraStatus> getCameraStatus(String deviceId) async =>
      CameraStatus.fromJson({
        'connected': true,
        'maxAdu': 65535,
        'canSetGain': true,
        'canSetOffset': true,
      });

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      CameraCapabilities.fromJson({
        'maxWidth': 100,
        'maxHeight': 100,
        'bitDepth': 16,
        'canSetGain': true,
        'canSetOffset': true,
        'gainMin': 0,
        'gainMax': 600,
        'offsetMin': 0,
        'offsetMax': 255,
      });

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
    commands.add((gain: gain, offset: offset));
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
      _image(_onTargetAdu);

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    savedHeaders.add(headerData);
    saveCount++;
    onSave?.call(saveCount);
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
    tempDir = Directory.systemTemp.createTempSync('flatwiz_snapshot');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(
    SkotiqBackend backend, {
    List<String> filterNames = const ['L', 'R'],
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        activeEquipmentProfileProvider.overrideWithValue(null),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        cameraStateProvider.overrideWith(
          (ref) => _SeededCameraNotifier(
            ref,
            const CameraStateSnapshot(
              connectionState: DeviceConnectionState.connected,
              deviceId: _cam,
              gain: 100,
              offset: 20,
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
    required int frameCount,
  }) async {
    final notifier = container.read(flatWizardProvider.notifier);
    await notifier.loadFiltersFromWheel();
    notifier.updateGlobalSettings(
      container
          .read(flatWizardProvider)
          .globalSettings
          .copyWith(
            savePath: tempDir.path,
            createDateSubfolder: false,
            createFilterSubfolders: false,
            frameCount: frameCount,
          ),
    );
    return notifier;
  }

  test(
    'a mid-run frame-count edit does not shrink the remaining filters',
    () async {
      late final FlatWizardNotifier notifier;
      final backend = _AutoBackend(
        onSave: (attempt) {
          if (attempt == 1) notifier.setFrameCount(1);
        },
      );
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      notifier = await primeWizard(container, frameCount: 3);
      notifier.setMode(FlatWizardMode.batch);

      await notifier.runCapture();

      expect(
        backend.saveCount,
        6,
        reason: 'both filters must capture the 3 frames the run started with',
      );
      final filters = container.read(flatWizardProvider).filterSettings;
      expect(filters[0].status, FilterCalibrationStatus.complete);
      expect(filters[1].status, FilterCalibrationStatus.complete);
      expect(filters[1].capturedCount, 3);
    },
  );

  test(
    'a mid-run histogram-target edit is not written to flat history',
    () async {
      late final FlatWizardNotifier notifier;
      final backend = _AutoBackend(
        onSave: (attempt) {
          if (attempt == 1) notifier.setHistogramTarget(20);
        },
      );
      addTearDown(backend.dispose);
      final container = makeContainer(backend, filterNames: const ['L']);
      notifier = await primeWizard(container, frameCount: 2);
      notifier.setMode(FlatWizardMode.quick);
      notifier.setCurrentFilterIndex(0);
      notifier.setHistogramTarget(50);

      await notifier.runCapture();

      final history = await db.flatHistoryDao.getRecentCalibrations(
        filterName: 'L',
      );
      expect(history, hasLength(1));
      expect(
        history.single.histogramTarget,
        50,
        reason:
            'history must record the target the frames were actually shot at',
      );
    },
  );
  test(
    'each filter tunes, captures and saves its own gain and offset',
    () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend, filterNames: const ['L', 'Ha']);
      final notifier = await primeWizard(container, frameCount: 1);
      notifier.setMode(FlatWizardMode.batch);
      for (var i = 0; i < 2; i++) {
        final filter = container.read(flatWizardProvider).filterSettings[i];
        notifier.updateFilterSettings(
          i,
          FlatFilterSettings.fromJson({
            ...filter.toJson(),
            'gainOverride': i == 0 ? 76 : 139,
            'offsetOverride': i == 0 ? 15 : 21,
          }),
        );
      }
      await notifier.runCapture();
      expect(backend.savedHeaders.map((h) => (h.gain, h.offset)), [
        (76, 15),
        (139, 21),
      ]);
      expect(
        backend.commands,
        [
          (gain: 76, offset: 15),
          (gain: 76, offset: 15),
          (gain: 139, offset: 21),
          (gain: 139, offset: 21),
        ],
        reason:
            'tuning and saved exposures must use the same per-filter settings',
      );
      final history = await db.flatHistoryDao.getRecentCalibrations(
        filterName: 'Ha',
      );
      expect(history.single.gain, 139);
    },
  );

  test(
    'invalid later-filter override prevents the entire run from starting',
    () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = await primeWizard(container, frameCount: 1);
      notifier.setMode(FlatWizardMode.batch);
      notifier.updateFilterSettings(
        1,
        container
            .read(flatWizardProvider)
            .filterSettings[1]
            .copyWith(gainOverride: 601),
      );
      await notifier.runCapture();
      expect(backend.commands, isEmpty);
      expect(backend.savedHeaders, isEmpty);
      expect(
        container.read(flatWizardProvider).errorMessage,
        contains('gain 601'),
      );
    },
  );

  test(
    'filter settings survive reload and restart without carrying run progress',
    () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = await primeWizard(container, frameCount: 1);
      notifier.updateFilterSettings(
        1,
        container
            .read(flatWizardProvider)
            .filterSettings[1]
            .copyWith(
              gainOverride: 139,
              offsetOverride: 21,
              frameCountOverride: 2,
            ),
      );
      await notifier.loadFiltersFromWheel();
      expect(
        container.read(flatWizardProvider).filterSettings[1].gainOverride,
        139,
      );
      const key = 'flat_wizard_filters.v1.[null,"native:cam:0",null]';
      for (var i = 0; i < 100; i++) {
        if ((await db.settingsDao.getSetting(key))?.contains('139') == true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await db.settingsDao.getSetting(key), contains('139'));
      final fresh = makeContainer(backend);
      await fresh.read(flatWizardProvider.notifier).loadFiltersFromWheel();
      final restored = fresh.read(flatWizardProvider).filterSettings[1];
      expect(
        (
          restored.gainOverride,
          restored.offsetOverride,
          restored.frameCountOverride,
        ),
        (139, 21, 2),
      );
      expect(restored.status, FilterCalibrationStatus.pending);
      expect(restored.capturedCount, 0);
      final freshNotifier = fresh.read(flatWizardProvider.notifier);
      freshNotifier.updateFilterSettings(
        1,
        restored.copyWith(gainOverride: null),
      );
      await freshNotifier.loadFiltersFromWheel();
      expect(
        fresh.read(flatWizardProvider).filterSettings[1].gainOverride,
        isNull,
      );
    },
  );

  test(
    'explicit zero is captured while a cleared override inherits the camera',
    () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend);
      final notifier = await primeWizard(container, frameCount: 1);
      notifier.setMode(FlatWizardMode.batch);
      notifier.updateFilterSettings(
        0,
        container
            .read(flatWizardProvider)
            .filterSettings[0]
            .copyWith(gainOverride: 0, offsetOverride: 0),
      );
      await notifier.runCapture();
      expect(backend.savedHeaders.map((h) => (h.gain, h.offset)), [
        (0, 0),
        (100, 20),
      ]);
    },
  );
  test('unsupported overrides fail instead of being silently ignored', () {
    const camera = FlatCaptureConfig(
      capabilitiesKnown: true,
      canSetGain: false,
    );
    expect(
      () => camera.forFilter(
        const FlatFilterSettings(
          filterName: 'Ha',
          filterPosition: 4,
          gainOverride: 139,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot set gain'),
        ),
      ),
    );
    expect(
      camera
          .forFilter(
            const FlatFilterSettings(filterName: 'Ha', filterPosition: 4),
          )
          .gain,
      isNull,
    );
  });
}
