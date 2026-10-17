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
      CameraStatus.fromJson({'connected': true, 'maxAdu': 65535});

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      CameraCapabilities.fromJson({
        'maxWidth': 100,
        'maxHeight': 100,
        'bitDepth': 16,
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
}
