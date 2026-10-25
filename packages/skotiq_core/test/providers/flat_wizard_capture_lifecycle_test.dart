// Deterministic, fake-backend coverage for the full flat-capture lifecycle
// driven by `FlatWizardNotifier.runCapture`.
//
// What these pin down:
//   * Stable per-filter indexing — quick mode with a nonzero current filter
//     and batch mode with disabled leading filters update the RIGHT rows.
//   * A save failure is a capture failure — no false "complete", no history
//     written when zero frames landed on disk; partial saves report `partial`.
//   * The final status message PERSISTS after the run (not cleared on exit).
//   * A second start while a run is active is rejected (busy latch), and the
//     camera-busy ownership check blocks a start when the camera is exposing.
//   * Remote routing is preserved: on a NetworkBackend the record goes to the
//     master via `recordFlat`, not the local DAO.
//   * Filename/subfolder components built from filter names are sanitized.
//
// The camera is a hand-rolled double that auto-completes each exposure on a
// microtask (so the whole loop runs without real delays) and returns an
// on-target ADU so calibration converges on the first iteration.

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
  // Names present (so the wizard seeds its filter list) but the wheel is
  // disconnected, so `_moveFilterWheel` short-circuits and never drives it.
  _SeededFilterWheelNotifier(super.ref, List<String> names) {
    state = FilterWheelState(filterNames: names);
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
    tempDir = Directory.systemTemp.createTempSync('flatwiz_lifecycle');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(
    SkotiqBackend backend, {
    List<String> filterNames = const ['L', 'R', 'G'],
    bool cameraExposing = false,
    bool cameraConnected = true,
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
            CameraStateSnapshot(
              connectionState: cameraConnected
                  ? DeviceConnectionState.connected
                  : DeviceConnectionState.disconnected,
              deviceId: cameraConnected ? _cam : null,
              gain: 100,
              offset: 20,
              isExposing: cameraExposing,
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

  /// Seed the wizard's filter list from the wheel and set a temp save path with
  /// no date subfolder (deterministic paths). Returns the notifier.
  Future<FlatWizardNotifier> primeWizard(
    ProviderContainer container, {
    int frameCount = 2,
    bool filterSubfolders = false,
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
            createFilterSubfolders: filterSubfolders,
            frameCount: frameCount,
          ),
    );
    return notifier;
  }

  group('stable per-filter indexing', () {
    test(
      'quick mode with a nonzero current filter updates the RIGHT row',
      () async {
        final backend = _AutoBackend();
        addTearDown(backend.dispose);
        final container = makeContainer(backend);
        final notifier = await primeWizard(container);

        // Quick mode captures ONLY the selected filter — here index 2 (G).
        notifier.setMode(FlatWizardMode.quick);
        notifier.setCurrentFilterIndex(2);

        await notifier.runCapture();

        final filters = container.read(flatWizardProvider).filterSettings;
        expect(
          filters[2].status,
          FilterCalibrationStatus.complete,
          reason: 'the selected row (2) must be the one marked complete',
        );
        expect(filters[2].capturedCount, 2);
        // Only the selected row may be written; these stay untouched.
        expect(filters[0].status, FilterCalibrationStatus.pending);
        expect(filters[0].capturedCount, 0);
        expect(filters[1].status, FilterCalibrationStatus.pending);
      },
    );

    test(
      'batch mode with a disabled leading filter updates the RIGHT rows',
      () async {
        final backend = _AutoBackend();
        addTearDown(backend.dispose);
        final container = makeContainer(backend);
        final notifier = await primeWizard(container);

        notifier.setMode(FlatWizardMode.batch);
        notifier.toggleFilter(0, false); // disable L; subset becomes [R, G]

        await notifier.runCapture();

        final filters = container.read(flatWizardProvider).filterSettings;
        // The disabled leading filter (row 0) stays untouched: the subset
        // must not shift onto it.
        expect(filters[0].status, FilterCalibrationStatus.pending);
        expect(filters[0].capturedCount, 0);
        expect(filters[1].status, FilterCalibrationStatus.complete);
        expect(filters[2].status, FilterCalibrationStatus.complete);
      },
    );
  });

  group('truthful outcomes and history', () {
    test('all frames failing to save => filter FAILED, no history, no false '
        'completion', () async {
      final backend = _AutoBackend(
        failSaveAt: (_) => true,
      ); // every save throws
      addTearDown(backend.dispose);
      final container = makeContainer(backend, filterNames: const ['L']);
      final notifier = await primeWizard(container, frameCount: 3);
      notifier.setMode(FlatWizardMode.quick);
      notifier.setCurrentFilterIndex(0);

      await notifier.runCapture();

      final state = container.read(flatWizardProvider);
      expect(state.filterSettings[0].status, FilterCalibrationStatus.failed);
      expect(state.filterSettings[0].capturedCount, 0);
      // No real files => no history recorded.
      final history = await db.flatHistoryDao.getRecentCalibrations(
        filterName: 'L',
      );
      expect(
        history,
        isEmpty,
        reason: 'history must not be written when zero frames were saved',
      );
      // Final outcome is a persisted failure, not a false "Complete".
      expect(state.statusMessage, isNotNull);
      expect(state.statusMessage!.toLowerCase(), contains('failed'));
      expect(state.errorMessage, isNotNull);
      expect(state.isCapturing, isFalse);
    });

    test(
      'some frames failing to save => filter PARTIAL, history recorded once',
      () async {
        // frameCount 2: first save succeeds, second throws => partial.
        var attempt = 0;
        final backend = _AutoBackend(failSaveAt: (_) => (++attempt) == 2);
        addTearDown(backend.dispose);
        final container = makeContainer(backend, filterNames: const ['L']);
        final notifier = await primeWizard(container, frameCount: 2);
        notifier.setMode(FlatWizardMode.quick);
        notifier.setCurrentFilterIndex(0);

        await notifier.runCapture();

        final state = container.read(flatWizardProvider);
        expect(state.filterSettings[0].status, FilterCalibrationStatus.partial);
        expect(state.filterSettings[0].capturedCount, 1);
        final history = await db.flatHistoryDao.getRecentCalibrations(
          filterName: 'L',
        );
        expect(
          history,
          hasLength(1),
          reason: 'a partial run with real files still records history',
        );
      },
    );

    test('final status PERSISTS after a fully successful run', () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend, filterNames: const ['L']);
      final notifier = await primeWizard(container, frameCount: 2);
      notifier.setMode(FlatWizardMode.quick);
      notifier.setCurrentFilterIndex(0);

      await notifier.runCapture();

      final state = container.read(flatWizardProvider);
      expect(state.isCapturing, isFalse);
      expect(state.isExposing, isFalse);
      expect(state.statusMessage, isNotNull);
      expect(state.statusMessage!.toLowerCase(), contains('complete'));
      expect(state.filterSettings[0].status, FilterCalibrationStatus.complete);
    });
  });

  group('guards', () {
    test('a second start while running is rejected (busy latch)', () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend, filterNames: const ['L']);
      final notifier = await primeWizard(container, frameCount: 2);
      notifier.setMode(FlatWizardMode.quick);
      notifier.setCurrentFilterIndex(0);

      final f1 = notifier.runCapture();
      final f2 = notifier.runCapture(); // must be a no-op
      await Future.wait([f1, f2]);

      // Exactly one run's worth of saves — an overlapping run would double it.
      expect(backend.saveCount, 2);
      expect(
        container.read(flatWizardProvider).filterSettings[0].capturedCount,
        2,
      );
    });

    test('camera busy with another exposure blocks the start', () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(
        backend,
        filterNames: const ['L'],
        cameraExposing: true,
      );
      final notifier = await primeWizard(container);
      notifier.setMode(FlatWizardMode.quick);

      await notifier.runCapture();

      final state = container.read(flatWizardProvider);
      expect(state.isCapturing, isFalse);
      expect(state.errorMessage, isNotNull);
      expect(state.errorMessage!.toLowerCase(), contains('busy'));
      expect(backend.startCount, 0, reason: 'no exposure should have started');
    });

    test('camera not connected blocks the start', () async {
      final backend = _AutoBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(
        backend,
        filterNames: const ['L'],
        cameraConnected: false,
      );
      final notifier = container.read(flatWizardProvider.notifier);
      // Seed filters manually (no wheel path needed for this negative case).
      await notifier.loadFiltersFromWheel();
      notifier.updateGlobalSettings(
        container
            .read(flatWizardProvider)
            .globalSettings
            .copyWith(savePath: tempDir.path),
      );
      notifier.setMode(FlatWizardMode.quick);

      await notifier.runCapture();

      final state = container.read(flatWizardProvider);
      expect(state.isCapturing, isFalse);
      expect(state.errorMessage, contains('Camera not connected'));
      expect(backend.startCount, 0);
    });
  });

  test('filename/subfolder components are sanitized', () async {
    final backend = _AutoBackend();
    addTearDown(backend.dispose);
    // A filter name containing path separators / illegal chars.
    final container = makeContainer(
      backend,
      filterNames: const [r'Ha/OIII:*?'],
    );
    final notifier = await primeWizard(
      container,
      frameCount: 1,
      filterSubfolders: true,
    );
    notifier.setMode(FlatWizardMode.quick);
    notifier.setCurrentFilterIndex(0);

    await notifier.runCapture();

    expect(backend.savedPaths, isNotEmpty);
    final saved = backend.savedPaths.single;
    // The raw separators/illegal chars must not survive into the path built
    // under the base temp dir (a stray '/OIII' would escape the intended dir).
    final relative = saved.substring(tempDir.path.length);
    expect(relative, isNot(contains(':')));
    expect(relative, isNot(contains('*')));
    expect(relative, isNot(contains('?')));
    // The single embedded '/' from the raw name must be gone (only the real
    // separators the code inserts remain).
    expect(
      RegExp(r'[/\\]').allMatches(relative).length,
      lessThanOrEqualTo(2),
      reason: 'raw slash in the filter name leaked into the path',
    );
  });

  test('saved flats are kept for the build step and recorded as raw '
      'calibration frames', () async {
    final backend = _AutoBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(backend, filterNames: const ['L', 'R']);
    final notifier = await primeWizard(container, frameCount: 2);
    notifier.setMode(FlatWizardMode.batch);

    await notifier.runCapture();

    final output = container.read(flatRunOutputProvider);
    expect(output.remote, isFalse);
    expect(output.filters.keys, ['L', 'R']);
    expect(output.filters['L']!.paths, hasLength(2));
    expect(output.frameCount, 4);
    final rows = await (db.select(
      db.capturedImages,
    )..where((t) => t.frameType.equals('flat'))).get();
    expect(rows, hasLength(4));
    expect(rows.map((r) => r.filter).toSet(), {'L', 'R'});
    expect(rows.map((r) => r.filePath).toSet(), {
      ...output.filters['L']!.paths,
      ...output.filters['R']!.paths,
    });
  });

  test(
    'flats saved on a remote host are kept but not recorded locally',
    () async {
      final backend = _AutoNetworkBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend, filterNames: const ['L']);
      final notifier = await primeWizard(container, frameCount: 2);
      notifier.setMode(FlatWizardMode.quick);
      notifier.setCurrentFilterIndex(0);

      await notifier.runCapture();

      final output = container.read(flatRunOutputProvider);
      expect(output.remote, isTrue);
      expect(output.filters['L']!.paths, hasLength(2));
      expect(await db.select(db.capturedImages).get(), isEmpty);
    },
  );

  test('remote backend routes history to the master via recordFlat', () async {
    final backend = _AutoNetworkBackend();
    addTearDown(backend.dispose);

    final container = makeContainer(backend, filterNames: const ['L']);
    final notifier = await primeWizard(container, frameCount: 2);
    notifier.setMode(FlatWizardMode.quick);
    notifier.setCurrentFilterIndex(0);

    await notifier.runCapture();

    // Remote routing: the master's recordFlat is called once; the LOCAL slave
    // DAO is never written (the master owns the flat library).
    expect(backend.recordFlatCalls, hasLength(1));
    expect(backend.recordFlatCalls.single.filter, 'L');
    expect(backend.recordFlatCalls.single.adu, isPositive);
    final local = await db.flatHistoryDao.getRecentCalibrations(
      filterName: 'L',
    );
    expect(
      local,
      isEmpty,
      reason: 'a remote session must not write to the local slave DB',
    );
    expect(
      container.read(flatWizardProvider).filterSettings[0].status,
      FilterCalibrationStatus.complete,
    );
    // Path behaviour is preserved (frames were routed to the save path).
    expect(backend.savedPaths, hasLength(2));
  });
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

/// Auto-completing camera double for the full-loop tests. Each exposure emits
/// `ExposureCompleted` on a microtask; `cameraGetLastImage` returns an on-target
/// frame so calibration converges immediately. `saveFitsFromLastCapture`
/// records the path and optionally throws per [failSaveAt].
class _AutoBackend extends Mock implements SkotiqBackend {
  _AutoBackend({this.failSaveAt});

  /// Called with the 1-based save attempt number; return true to make that
  /// FITS write throw (modelling a disk/permission failure).
  final bool Function(int attempt)? failSaveAt;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  int startCount = 0;
  int saveCount = 0;
  int _saveAttempts = 0;
  final List<String> savedPaths = [];
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
    startCount++;
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
    _saveAttempts++;
    if (failSaveAt?.call(_saveAttempts) ?? false) {
      throw Exception('simulated FITS write failure');
    }
    saveCount++;
    savedPaths.add(filePath);
  }
}

/// A recorded `recordFlat` invocation.
class _RecordFlatCall {
  final String filter;
  final double exposureDuration;
  final int adu;
  const _RecordFlatCall(this.filter, this.exposureDuration, this.adu);
}

/// Auto-completing camera double that ALSO implements [NetworkBackend], so the
/// wizard takes the remote history path (`recordFlat` on the master) instead of
/// the local DAO. Capture behaviour mirrors [_AutoBackend]; real method
/// overrides (not mocktail stubs) keep the whole capture loop deterministic.
class _AutoNetworkBackend extends Mock implements NetworkBackend {
  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final List<String> savedPaths = [];
  final List<_RecordFlatCall> recordFlatCalls = [];
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
  Future<Map<String, dynamic>> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
  }) async => {'valid': true, 'normalizedPath': path};

  // Remote client seeds suggestions from the master; empty history here.
  @override
  Future<List<RemoteFlatHistoryEntry>> listFlats({
    String? filter,
    int? equipmentProfileId,
    int? gain,
    DateTime? since,
    int? limit,
  }) async => const [];

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
    savedPaths.add(filePath);
  }

  @override
  Future<RemoteFlatHistoryEntry> recordFlat({
    required String filter,
    required double exposureDuration,
    required int adu,
    double histogramTarget = 50.0,
    int gain = 0,
    int binning = 1,
    int? panelBrightness,
    double? skyAduRate,
    String? twilightPhase,
    int? equipmentProfileId,
  }) async {
    recordFlatCalls.add(_RecordFlatCall(filter, exposureDuration, adu));
    return RemoteFlatHistoryEntry(
      id: recordFlatCalls.length,
      filter: filter,
      exposureDuration: exposureDuration,
      histogramTarget: histogramTarget,
      adu: adu,
      gain: gain,
      binning: binning,
      panelBrightness: panelBrightness,
      skyAduRate: skyAduRate,
      twilightPhase: twilightPhase,
      equipmentProfileId: equipmentProfileId,
      createdAt: DateTime.now(),
    );
  }
}
