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
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../mocks/mock_database.dart';
import '../harness/event_wire.dart';

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

  void use(SkotiqBackend backend) => state = backend;
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
  int exposureStarts = 0;
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
    exposureStarts++;
    if (blockExposure) return; // never completes — the run parks
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(
        cameraTaggedWireEvent(
          const bridge.EventPayload.imaging(
            bridge.ImagingEvent.exposureCompleted(hfr: 2, starsDetected: 0),
          ),
          deviceId: deviceId,
          timestamp: ++_seq,
        ),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(
    String deviceId, {
    int? maxWidth,
  }) async => _image(32768);

  @override
  Future<String> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
    bool keepCameraFile = false,
  }) async {
    saveCount++;
    onSave?.call();
    return filePath;
  }
}

/// NetworkBackend whose flat-history write always FAILS, to prove the failure is
/// surfaced (warning) rather than silently swallowed.
class _OfflineMasterHistory extends Mock implements HostCalibrationFrames {}

class _ThrowingHistoryBackend extends Mock implements NetworkBackend {
  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final List<String> savedPaths = [];
  final List<Map<String, dynamic>> startBodies = [];
  Completer<Map<String, dynamic>>? pendingStart;
  final preview = Completer<CapturedImageResult>();
  int cancels = 0;

  @override
  Future<CapturedImageResult> getFlatWizardPreview(String key) =>
      preview.future;

  @override
  Future<Map<String, dynamic>> cancelFlatWizardRun() async {
    cancels++;
    return {};
  }

  int exposureStarts = 0;
  int _seq = 0;

  @override
  Future<Map<String, dynamic>> startFlatWizardRun(
    Map<String, dynamic> draft,
  ) async {
    startBodies.add(draft);
    if (pendingStart != null) return pendingStart!.future;
    return {'state': draft, 'busy': false, 'output': {}};
  }

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
    bool create = false,
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
    exposureStarts++;
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(
        cameraTaggedWireEvent(
          const bridge.EventPayload.imaging(
            bridge.ImagingEvent.exposureCompleted(hfr: 2, starsDetected: 0),
          ),
          deviceId: deviceId,
          timestamp: ++_seq,
        ),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(
    String deviceId, {
    int? maxWidth,
  }) async => _image(32768);

  @override
  Future<String> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
    bool keepCameraFile = false,
  }) async {
    savedPaths.add(filePath);
    return filePath;
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
    registerFallbackValue(DateTime.utc(2020));
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
    List<String>? profileFilters,
    bool cameraConnected = true,
    List<Override> extraOverrides = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        activeEquipmentProfileProvider.overrideWithValue(
          profileFilters == null
              ? null
              : EquipmentProfileModel(name: 'Rig', filterNames: profileFilters),
        ),
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
        ...extraOverrides,
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
    await notifier.loadFilters();
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

  test(
    'with no wheel connected the wizard lists the profile\'s filters',
    () async {
      final backend = _WorkflowBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(
        backend,
        wheel: const FilterWheelState(),
        profileFilters: const ['L', 'Ha'],
      );

      await primeWizard(container);

      expect(
        [
          for (final f in container.read(flatWizardProvider).filterSettings)
            f.filterName,
        ],
        ['L', 'Ha'],
      );
    },
  );

  test('a batch of several filters without a wheel is refused before any '
      'frame', () async {
    final backend = _WorkflowBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(),
      profileFilters: const ['L', 'Ha'],
    );
    final notifier = await primeWizard(container);
    notifier.setMode(FlatWizardMode.batch);

    await notifier.runCapture();

    final state = container.read(flatWizardProvider);
    expect(state.errorMessage, contains('Connect a filter wheel'));
    expect(backend.saveCount, 0);
    expect(state.isCapturing, isFalse);
  });

  test('a filter-wheel move FAILURE stops the run. No flat through an unknown '
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
          'stale cache. Otherwise the flat is shot through the wrong filter',
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
        wheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          filterNames: ['L', 'R'],
        ),
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
    final frames = _OfflineMasterHistory();
    when(
      () => frames.listFlats(
        filter: any(named: 'filter'),
        equipmentProfileId: any(named: 'equipmentProfileId'),
        gain: any(named: 'gain'),
        since: any(named: 'since'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const []);
    when(
      () => frames.recordFlat(
        filter: any(named: 'filter'),
        exposureDuration: any(named: 'exposureDuration'),
        adu: any(named: 'adu'),
        histogramTarget: any(named: 'histogramTarget'),
        gain: any(named: 'gain'),
        binning: any(named: 'binning'),
        panelBrightness: any(named: 'panelBrightness'),
        skyAduRate: any(named: 'skyAduRate'),
        twilightPhase: any(named: 'twilightPhase'),
        equipmentProfileId: any(named: 'equipmentProfileId'),
      ),
    ).thenThrow(StateError('master offline'));
    final backend = _WorkflowBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        filterNames: ['L'],
      ),
      filterNames: const ['L'],
      extraOverrides: [
        linkedHostCalibrationFramesProvider.overrideWithValue(frames),
      ],
    );
    final notifier = await primeWizard(container);

    await notifier.runCapture();

    final state = container.read(flatWizardProvider);
    // The frame landed on disk and the filter is complete…
    expect(backend.saveCount, greaterThan(0));
    expect(state.filterSettings[0].status, FilterCalibrationStatus.complete);
    // …but the library write failure is surfaced, not swallowed.
    expect(state.warningMessage, isNotNull);
    expect(state.warningMessage!.toLowerCase(), contains('did not record'));
    // The master owns the flat library; the failed post did not land locally.
    final local = await db.flatHistoryDao.getRecentCalibrations(
      filterName: 'L',
    );
    expect(local, isEmpty);
  });

  test(
    'flat admission protects the sequence, manual camera and start prompt',
    () async {
      final backend = _WorkflowBackend();
      addTearDown(backend.dispose);
      final container = makeContainer(backend, wheel: const FilterWheelState());
      final wizard = await primeWizard(container);
      final draft = container.read(flatWizardProvider);
      final record = container.read(runRecordProvider.notifier);
      record.setLaunching(true);
      expect(wizard.startHostRun(draft), isFalse);
      await wizard.runCapture();
      expect(
        container.read(flatWizardProvider).errorMessage,
        contains('sequencer'),
      );
      record.setLaunching(false);
      record.setLifecycle(SequenceExecutionState.paused);
      expect(wizard.startHostRun(draft), isFalse);
      record.setLifecycle(SequenceExecutionState.completed);
      container.read(sessionStateProvider.notifier).setCapturing(true);
      expect(wizard.startHostRun(draft), isFalse);
      container.read(sessionStateProvider.notifier).setCapturing(false);
      container.read(cameraStateProvider.notifier).setExposing(true);
      expect(wizard.startHostRun(draft), isFalse);
      container.read(cameraStateProvider.notifier).setExposing(false);
      container.read(rawCameraExposureInFlightProvider.notifier).state = true;
      expect(wizard.startHostRun(draft), isFalse);
      container.read(rawCameraExposureInFlightProvider.notifier).state = false;
      expect(wizard.reserveStartPrompt(), isTrue);
      expect(wizard.startHostRun(draft), isFalse);
      wizard.releaseStartPrompt();
      expect(wizard.startBlockReason, isNull);
      expect(backend.exposureStarts, 0);
    },
  );

  test(
    'a linked start leaves the default folder to the host and orders cancellation after admission',
    () async {
      final host = _ThrowingHistoryBackend()..pendingStart = Completer();
      addTearDown(host.dispose);
      final container = makeContainer(host, wheel: const FilterWheelState());
      final wizard = await primeWizard(container);
      wizard.updateGlobalSettings(
        container
            .read(flatWizardProvider)
            .globalSettings
            .copyWith(savePath: null),
      );
      final started = wizard.runCapture();
      final body = host.startBodies.single;
      expect((body['globalSettings'] as Map)['savePath'], isNull);
      wizard.requestCancel();
      expect(host.cancels, 0);
      host.pendingStart!.complete({'state': body, 'busy': true, 'output': {}});
      await started;
      expect(host.cancels, 1);
      expect(host.exposureStarts, 0);
    },
  );

  test(
    'switching hosts drops the old run, preview and pending commands',
    () async {
      final oldHost = _ThrowingHistoryBackend()..pendingStart = Completer();
      final newHost = _ThrowingHistoryBackend();
      addTearDown(oldHost.dispose);
      addTearDown(newHost.dispose);
      final container = makeContainer(oldHost, wheel: const FilterWheelState());
      final wizard = await primeWizard(container);
      final starting = wizard.runCapture();
      final old = {
        'state': oldHost.startBodies.single,
        'busy': true,
        'output': {},
        'previewKey': 'old',
      };
      wizard.applyHostSnapshot(FlatRunSnapshot.fromJson(old));
      expect(wizard.isBusy, isTrue);
      (container.read(backendProvider.notifier) as _FixedBackendNotifier).use(
        newHost,
      );
      wizard.requestCancel();
      oldHost.pendingStart!.complete(old);
      oldHost.preview.complete(_image(1000));
      await starting;
      await _pump();
      expect(wizard.isBusy, isFalse);
      expect(container.read(flatWizardProvider).lastImageData, isNull);
      expect(
        container.read(flatWizardProvider).globalSettings.savePath,
        isNull,
      );
      expect(container.read(flatRunOutputProvider).remote, isFalse);
      expect(oldHost.cancels, 0);
      expect(newHost.cancels, 0);
    },
  );

  test(
    'the last streamed state wins over a late start reply and keeps the selected tab',
    () async {
      final host = _ThrowingHistoryBackend()..pendingStart = Completer();
      addTearDown(host.dispose);
      final container = makeContainer(host, wheel: const FilterWheelState());
      final wizard = await primeWizard(container);
      wizard.setMode(FlatWizardMode.batch);
      wizard.toggleAduGraph(false);
      final start = wizard.runCapture();
      final state = {
        ...host.startBodies.single,
        'mode': 'quick',
        'showAduGraph': true,
      };
      wizard.applyHostSnapshot(
        FlatRunSnapshot.fromJson({
          'state': {...state, 'statusMessage': 'Completed'},
          'busy': false,
          'output': {},
        }),
      );
      host.pendingStart!.complete({'state': state, 'busy': true, 'output': {}});
      await start;
      expect(wizard.isBusy, isFalse);
      final shown = container.read(flatWizardProvider);
      expect(shown.mode, FlatWizardMode.batch);
      expect(shown.showAduGraph, isFalse);
      expect(shown.statusMessage, 'Completed');
    },
  );

  test('a linked Windows host gets flat paths in its own path style', () async {
    final backend = _ThrowingHistoryBackend();
    addTearDown(backend.dispose);
    final container = makeContainer(
      backend,
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        filterNames: ['L'],
      ),
      filterNames: const ['L'],
    );
    final notifier = await primeWizard(container);
    notifier.updateGlobalSettings(
      container
          .read(flatWizardProvider)
          .globalSettings
          .copyWith(
            savePath: r'C:\Users\observer\Documents\Flats',
            createDateSubfolder: true,
            createFilterSubfolders: true,
          ),
    );

    await notifier.runCapture();

    // The client sends the host path unchanged and does not build the files.
    // The imaging host joins subfolders in its own path style when it runs.
    expect(backend.startBodies, hasLength(1));
    expect(backend.exposureStarts, 0);
    expect(backend.savedPaths, isEmpty);
    final settings =
        backend.startBodies.single['globalSettings'] as Map<String, dynamic>;
    expect(settings['savePath'], r'C:\Users\observer\Documents\Flats');
    expect(settings['createDateSubfolder'], isTrue);
    expect(settings['createFilterSubfolders'], isTrue);
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
        wheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          filterNames: ['L', 'R'],
        ),
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
      await notifier.loadFilters();

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
        wheel: const FilterWheelState(
          connectionState: DeviceConnectionState.connected,
          filterNames: ['L'],
        ),
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
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        filterNames: ['L'],
      ),
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
      wheel: const FilterWheelState(
        connectionState: DeviceConnectionState.connected,
        filterNames: ['L'],
      ),
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
