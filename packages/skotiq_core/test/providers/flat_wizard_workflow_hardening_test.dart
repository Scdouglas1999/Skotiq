// Adversarial workflow-hardening tests for the flat-capture lane.
//
// These pin the residual-fix contract added on top of the lifecycle rewrite:
//   * A filter-wheel move that FAILS stops the whole run (never captures a flat
//     through an unknown filter) — no silent swallow.
//   * The filter-wheel settle is STATE-DRIVEN: capture does not begin until the
//     wheel reports it has stopped moving (not a blind fixed delay).
//   * Both the settle and the "already there, skip the move" decision are read
//     from the DEVICE, never from the cached provider — nothing publishes a
//     position event on a bare filterWheelSetPosition, so a cached position can
//     be wrong in either direction (the move never confirms, or a needed move is
//     skipped and the flat is shot through the wrong filter).
//   * A mid-run camera disconnect fails the run FAST (between filters), not only
//     after a full exposure timeout.
//   * A flat-history write failure surfaces a NON-FATAL warning (de-silenced
//     from a release-stripped debugPrint); the frames are still saved.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../mocks/mock_database.dart';

const String _cam = 'native:cam:0';
const String _fw = 'native:fw:0';

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

class _MutableCameraNotifier extends CameraStateNotifier {
  _MutableCameraNotifier(super.ref, CameraStateSnapshot seed) {
    state = seed;
  }

  void set(CameraStateSnapshot s) => state = s;
}

class _MutableFilterWheelNotifier extends FilterWheelStateNotifier {
  _MutableFilterWheelNotifier(super.ref, FilterWheelState seed) {
    state = seed;
  }

  void set(FilterWheelState s) => state = s;
}

/// Auto-completing camera with configurable filter-wheel-move + save behaviour.
///
/// [blockExposure] parks the run: no `ExposureCompleted` is ever emitted, so
/// the notifier stays latched (`_running`) at the first exposure until the run
/// is cancelled — used to exercise mid-run re-entry guards deterministically.
class _WorkflowBackend extends Mock implements SkotiqBackend {
  _WorkflowBackend({
    this.failWheelMove = false,
    this.onSave,
    this.blockExposure = false,
  });

  final bool failWheelMove;
  final void Function()? onSave;
  final bool blockExposure;

  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  int saveCount = 0;
  final List<int> wheelMoves = [];
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

  /// What the wheel REPORTS, independently of what it was told to do.
  ///
  /// The settle loop reads the wheel from the backend rather than from the
  /// provider (a provider nothing refreshed could never change, so every filter
  /// move failed closed after the full timeout). Tests therefore drive
  /// settling by moving these, not by poking the provider.
  int wheelPosition = 0;
  bool wheelMoving = false;

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    if (failWheelMove) throw StateError('wheel jammed');
    wheelMoves.add(position);
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async =>
      FilterWheelStatus(
        connected: true,
        position: wheelPosition,
        moving: wheelMoving,
        filterCount: 2,
        filterNames: const ['L', 'R'],
      );

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
    if (blockExposure) return; // never completes — the run parks
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
      _image(32768);

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    saveCount++;
    onSave?.call();
  }
}

/// NetworkBackend whose flat-history write always FAILS, to prove the failure is
/// surfaced (warning) rather than silently swallowed.
class _ThrowingHistoryBackend extends Mock implements NetworkBackend {
  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
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
  Future<Map<String, dynamic>> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
  }) async => {'valid': true, 'normalizedPath': path};

  @override
  Future<List<RemoteFlatHistoryEntry>> listFlats({
    String? filter,
    int? equipmentProfileId,
    int? gain,
    DateTime? since,
    int? limit,
  }) async => const [];

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
      _image(32768);

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
    throw StateError('master offline');
  }
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
    tempDir = Directory.systemTemp.createTempSync('flatwiz_workflow');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer(
    SkotiqBackend backend, {
    required FilterWheelState wheel,
    List<String> filterNames = const ['L', 'R'],
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
          (ref) => _MutableCameraNotifier(
            ref,
            CameraStateSnapshot(
              connectionState: cameraConnected
                  ? DeviceConnectionState.connected
                  : DeviceConnectionState.disconnected,
              deviceId: cameraConnected ? _cam : null,
              gain: 100,
              offset: 20,
            ),
          ),
        ),
        filterWheelStateProvider.overrideWith(
          (ref) => _MutableFilterWheelNotifier(ref, wheel),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<FlatWizardNotifier> primeWizard(
    ProviderContainer container, {
    int frameCount = 1,
    int currentFilterIndex = 0,
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
    notifier.setMode(FlatWizardMode.quick);
    notifier.setCurrentFilterIndex(currentFilterIndex);
    return notifier;
  }

  test('a filter-wheel move FAILURE stops the run — no flat through an unknown '
      'filter', () async {
    final backend = _WorkflowBackend(failWheelMove: true);
    addTearDown(backend.dispose);
    // Wheel connected at position 0; target filter R is at position 1 → a real
    // move is attempted (and jams).
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        deviceId: _fw,
        filterNames: ['L', 'R'],
        currentPosition: 0,
      ),
    );
    final notifier = await primeWizard(container, currentFilterIndex: 1);

    await notifier.runCapture();

    final state = container.read(flatWizardProvider);
    expect(backend.saveCount, 0, reason: 'no flat captured after a move fault');
    expect(state.filterSettings[1].status, FilterCalibrationStatus.failed);
    expect(state.errorMessage, isNotNull);
    expect(state.errorMessage!.toLowerCase(), contains('filter wheel'));
    expect(state.statusMessage!.toLowerCase(), contains('run stopped'));
    expect(state.isCapturing, isFalse);
  });

  test(
    'capture waits for the filter wheel to STOP MOVING before exposing',
    () async {
      final backend = _WorkflowBackend();
      addTearDown(backend.dispose);
      // Wheel connected but still MOVING toward position 1.
      final container = makeContainer(
        backend,
        wheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          deviceId: _fw,
          filterNames: ['L', 'R'],
          currentPosition: 0,
          isMoving: true,
        ),
      );
      final notifier = await primeWizard(container, currentFilterIndex: 1);

      final run = notifier.runCapture();
      // Let the run reach the wheel-settle poll and spin a few ticks.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        backend.saveCount,
        0,
        reason: 'must NOT expose/save while the wheel is still moving',
      );
      expect(backend.wheelMoves, contains(1), reason: 'the move was commanded');

      // The wheel finishes moving and reports settled at the target. Driven
      // through the backend because that is what the settle loop reads.
      backend.wheelMoving = false;
      backend.wheelPosition = 1;
      await run;

      expect(
        backend.saveCount,
        1,
        reason: 'capture proceeds only after the wheel settles',
      );
      expect(
        container.read(flatWizardProvider).filterSettings[1].status,
        FilterCalibrationStatus.complete,
      );
    },
  );

  test('an unreported filter position times out fail-closed', () async {
    final backend = _WorkflowBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        deviceId: _fw,
        filterNames: ['L', 'R'],
        currentPosition: 0,
      ),
    );
    final notifier = container.read(flatWizardProvider.notifier);

    final error = await notifier.moveFilterWheelAndWait(
      1,
      FlatCancelToken(),
      maxWait: const Duration(milliseconds: 30),
      pollInterval: const Duration(milliseconds: 5),
      settleFloor: Duration.zero,
    );

    expect(backend.wheelMoves, [1]);
    expect(error, contains('did not confirm position 1'));
    expect(backend.saveCount, 0);
  });

  test('a completed move is confirmed from the DEVICE, not from a provider '
      'nothing refreshes', () async {
    final backend = _WorkflowBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        deviceId: _fw,
        filterNames: ['L', 'R'],
        currentPosition: 0,
      ),
    );
    final notifier = container.read(flatWizardProvider.notifier);

    final move = notifier.moveFilterWheelAndWait(
      1,
      FlatCancelToken(),
      maxWait: const Duration(seconds: 2),
      pollInterval: const Duration(milliseconds: 5),
      settleFloor: Duration.zero,
    );
    // The DEVICE completes the move. Nothing pushes a position event and the
    // test never pokes the provider — exactly the shape that made every flat
    // run with a filter change time out after the full 15 s.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    backend.wheelPosition = 1;

    expect(await move, isNull, reason: 'the settle must see the real wheel');
    expect(backend.wheelMoves, [1]);
    expect(
      container.read(filterWheelStateProvider).currentPosition,
      1,
      reason: 'the confirmed position is pushed back into the provider',
    );
  });

  test('a provider that wrongly claims the wheel is already on target does NOT '
      'skip the move', () async {
    final backend = _WorkflowBackend();
    addTearDown(backend.dispose);
    // The DEVICE is on position 0 while the provider still believes 1 — what a
    // filter move made outside DeviceService (e.g. the headless endpoint the
    // web dashboard calls) leaves behind, since no position event is published.
    backend.wheelPosition = 0;
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        deviceId: _fw,
        filterNames: ['L', 'R'],
        currentPosition: 1,
      ),
    );
    final notifier = container.read(flatWizardProvider.notifier);

    final move = notifier.moveFilterWheelAndWait(
      1,
      FlatCancelToken(),
      maxWait: const Duration(seconds: 2),
      pollInterval: const Duration(milliseconds: 5),
      settleFloor: Duration.zero,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    backend.wheelPosition = 1;

    expect(await move, isNull);
    expect(
      backend.wheelMoves,
      [1],
      reason:
          'the move is commanded against the device, not skipped on a '
          'stale cache — otherwise the flat is shot through the wrong filter',
    );
  });

  test(
    'a mid-run camera disconnect stops the run fast (between filters)',
    () async {
      late _MutableCameraNotifier cameraNotifier;
      // After the first filter's frame is saved, drop the camera.
      final backend = _WorkflowBackend(
        onSave: () => cameraNotifier.set(
          const CameraStateSnapshot(
            connectionState: DeviceConnectionState.disconnected,
          ),
        ),
      );
      addTearDown(backend.dispose);
      // No wheel (disconnected) so the move path is a no-op; batch two filters.
      final container = makeContainer(
        backend,
        wheel: const FilterWheelState(filterNames: ['L', 'R']),
      );
      cameraNotifier =
          container.read(cameraStateProvider.notifier)
              as _MutableCameraNotifier;
      final notifier = await primeWizard(container);
      notifier.setMode(FlatWizardMode.batch); // capture both L and R

      await notifier.runCapture();
      await _pump();

      final state = container.read(flatWizardProvider);
      // First filter completed and saved before the drop…
      expect(state.filterSettings[0].status, FilterCalibrationStatus.complete);
      // …the second was never started (fast-fail at the filter-loop top).
      expect(state.filterSettings[1].status, FilterCalibrationStatus.pending);
      expect(backend.saveCount, 1);
      expect(state.errorMessage, isNotNull);
      expect(state.errorMessage!.toLowerCase(), contains('disconnect'));
      expect(state.isCapturing, isFalse);
    },
  );

  test('a flat-history write failure surfaces a NON-FATAL warning; frames are '
      'still saved', () async {
    final backend = _ThrowingHistoryBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(filterNames: ['L']),
      filterNames: const ['L'],
    );
    final notifier = await primeWizard(container);

    await notifier.runCapture();

    final state = container.read(flatWizardProvider);
    // The frame landed on disk and the filter is complete…
    expect(backend.savedPaths, isNotEmpty);
    expect(state.filterSettings[0].status, FilterCalibrationStatus.complete);
    // …but the library write failure is surfaced, not swallowed.
    expect(state.warningMessage, isNotNull);
    expect(state.warningMessage!.toLowerCase(), contains('did not record'));
    // A remote session must not have written to the local slave DB either.
    final local = await db.flatHistoryDao.getRecentCalibrations(
      filterName: 'L',
    );
    expect(local, isEmpty);
  });

  test(
    're-loading filters mid-run is a NO-OP (live bookkeeping is not wiped)',
    () async {
      // The exposure never completes, so the run stays latched at the first
      // filter's calibration with `_running` true.
      final backend = _WorkflowBackend(blockExposure: true);
      addTearDown(backend.dispose);
      final container = makeContainer(
        backend,
        wheel: const FilterWheelState(filterNames: ['L', 'R']),
      );
      final notifier = await primeWizard(container);
      notifier.setMode(FlatWizardMode.batch);

      final run = notifier.runCapture();
      // Let the run reach the (never-completing) calibration exposure.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final before = container.read(flatWizardProvider).filterSettings;
      expect(before[0].status, FilterCalibrationStatus.calibrating);

      // A screen re-entry (postFrameCallback) fires this on every init. Mid-run it
      // must be a no-op — rebuilding the list would reset statuses/counts and
      // corrupt the truthful final summary.
      await notifier.loadFiltersFromWheel();

      final after = container.read(flatWizardProvider).filterSettings;
      expect(after.length, before.length);
      expect(
        after[0].status,
        FilterCalibrationStatus.calibrating,
        reason: 'the live run row must not be reset to pending',
      );

      // Unwind the parked run.
      notifier.requestCancel();
      await run;
      expect(container.read(flatWizardProvider).isCapturing, isFalse);
    },
  );

  test(
    'browsing to Sky Flats mid-run does NOT switch the recorded algorithm',
    () async {
      // Switch the mode to sky-flats/dawn the moment the (quick, normal) frame is
      // saved — i.e. while `_running` is true and before history is recorded.
      late FlatWizardNotifier notifier;
      final backend = _WorkflowBackend(
        onSave: () {
          notifier.setMode(FlatWizardMode.skyFlats);
          notifier.setTwilightMode(TwilightMode.dawn);
        },
      );
      addTearDown(backend.dispose);
      final container = makeContainer(
        backend,
        wheel: const FilterWheelState(filterNames: ['L']),
        filterNames: const ['L'],
      );
      notifier = await primeWizard(container);

      await notifier.runCapture();

      // The run committed as a NORMAL (quick) calibration, so its history record
      // carries no twilight phase / sky-rate even though the tab was flipped to
      // Sky Flats mid-run.
      final history = await db.flatHistoryDao.getRecentCalibrations(
        filterName: 'L',
      );
      expect(history, hasLength(1));
      expect(
        history.single.twilightPhase,
        isNull,
        reason: 'mid-run tab switch must not retro-tag the run as sky-flats',
      );
      expect(history.single.skyAduRate, isNull);
    },
  );

  test('global settings persist across a fresh notifier (survive an app '
      'restart)', () async {
    final backend1 = _WorkflowBackend();
    addTearDown(backend1.dispose);
    final container1 = makeContainer(
      backend1,
      wheel: const FilterWheelState(filterNames: ['L']),
      filterNames: const ['L'],
    );
    final notifier1 = container1.read(flatWizardProvider.notifier);
    notifier1.setSavePath('/tmp/flats-restored');
    notifier1.setHistogramTarget(42);
    notifier1.setFrameCount(7);
    // Let the fire-and-forget persist writes land in the shared DB.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // A brand-new notifier over the SAME database models the next app launch:
    // its constructor hydrates the persisted settings back into state.
    final backend2 = _WorkflowBackend();
    addTearDown(backend2.dispose);
    final container2 = makeContainer(
      backend2,
      wheel: const FilterWheelState(filterNames: ['L']),
      filterNames: const ['L'],
    );
    container2.read(flatWizardProvider.notifier); // fires the async hydrate
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final restored = container2.read(flatWizardProvider).globalSettings;
    expect(restored.savePath, '/tmp/flats-restored');
    expect(restored.histogramTarget, 42);
    expect(restored.frameCount, 7);
  });
}
