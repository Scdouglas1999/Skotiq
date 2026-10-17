// Stack-and-Share Loop — tests for the orchestrator service.
//
// The provider test (stack_and_share_provider_test.dart) substitutes a fake
// StackAndShareService, so the real run() body — the busy guard, the
// reference-first ordering, the per-frame accept/reject accounting, the
// calibration-on vs calibration-off path split, and the always-release
// `finally` — is only reached from here. This file drives the REAL
// StackAndShareService end-to-end against:
//
//   * a fake [StackingEngineSeam] (injected directly) standing in for the
//     native stacker singleton + raw FITS / stretch bridge calls;
//   * a fake [LiveStackingService] (provider override) for the per-frame add +
//     final getCurrentResult calls;
//   * a fake [StackLightSelector] (provider override) producing a scripted
//     selection;
//   * a real in-memory database for the session lookup + result persistence.
//
// What it pins:
//   (a) LiveStackBusyException when the engine reports active;
//   (b) the reference frame is processed first, then the followers in order;
//   (c) framesRejected increments only when the engine's stacked count does
//       not advance for a follower;
//   (d) the engine is STOPPED (not reset) in the finally even when a mid-run
//       step throws — so a subsequent run is not blocked by a wedged singleton;
//   (e) calibration-off uses the file path (startFromFile / addFrameFromFile)
//       and calibration-on uses the data path (startFromData / addFrameFromData
//       fed by readLinearFrame).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/daos/stacked_results_dao.dart';
import 'package:skotiq_core/src/models/imaging/stack_and_share_models.dart';
import 'package:skotiq_core/src/providers/auto_stretch_provider.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/capability_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';
import 'package:skotiq_core/src/services/stack_and_share_service.dart';
import 'package:skotiq_core/src/services/stack_light_selector.dart';
import 'package:skotiq_core/src/services/stacking_engine_seam.dart';

/// A record of every call the orchestrator makes through the stacking seam, in
/// order, so tests can assert the path taken (file vs data) and that stop was
/// invoked.
class _FakeStackingEngine implements StackingEngineSeam {
  _FakeStackingEngine({this.active = false, this.framePattern});

  /// What [isActive] returns (the busy guard reads this).
  bool active;

  /// Bayer pattern reported by [readLinearFrame] for the reference frame (the
  /// file-path OSC signal). `null` keeps the frame mono (no CFA geometry).
  final String? framePattern;

  /// Ordered log of seam interactions: `startFile:PATH`, `startData:WxH`,
  /// `read:PATH`, `stretch`, `stop`.
  final List<String> calls = <String>[];

  /// The engine config captured from the most recent start call, so tests can
  /// assert the resolved OSC sensor mode + Bayer pattern reached the engine.
  LiveStackingConfig? lastStartConfig;

  int stopCount = 0;

  @override
  bool isActive() => active;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    required LiveStackingConfig config,
  }) async {
    calls.add('startFile:$referenceImagePath');
    lastStartConfig = config;
    return const LiveStackingStats(stackedFrameCount: 1);
  }

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    required LiveStackingConfig config,
  }) async {
    calls.add('startData:${width}x$height');
    lastStartConfig = config;
    return const LiveStackingStats(stackedFrameCount: 1);
  }

  @override
  Future<LinearFrameData> readLinearFrame(String filePath) async {
    calls.add('read:$filePath');
    // A tiny 2x2 frame of mid-range linear samples; [framePattern] decides
    // whether it advertises CFA geometry (the file-path OSC signal).
    return LinearFrameData(
      width: 2,
      height: 2,
      linearData: const [100.0, 200.0, 300.0, 400.0],
      bayerPattern: framePattern,
    );
  }

  /// Channel count passed to the most recent [autoStretch] call (`1` for a
  /// mono stretch, `3` for an OSC/colour stretch), or `null` if never called.
  int? lastStretchChannels;

  @override
  Uint8List autoStretch({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) {
    calls.add('stretch');
    lastStretchChannels = channels;
    return Uint8List(width * height * 4);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    calls.add('stop');
  }
}

/// A [StackingEngineSeam] that faithfully mirrors the native bridge's
/// sensor-mode contract (`parse_sensor_mode` + the OSC-without-pattern hard
/// error in `stacking_api.rs`), so a test can prove the *resolved*
/// [LiveStackingConfig] the orchestrator hands to a start call is one the real
/// native path actually accepts.
///
/// The plain [_FakeStackingEngine] ignores `sensorMode` entirely, which would
/// mask a Dart/native mismatch (e.g. the default `auto` mono run). This fake
/// replicates the three native states:
///
///   * `mono` — never debayers; always starts.
///   * `osc`  — requires a resolvable Bayer pattern; without one, the start
///     throws exactly as the native `stacking_start*` functions return
///     `Err("OSC declared but no Bayer pattern resolvable…")`.
///   * `auto` — debayers only when a pattern resolves; a missing pattern is
///     mono, never an error.
///
/// [filePattern] is the Bayer geometry the native FITS reader would expose for
/// the reference frame (the file-path detection source); `null` = mono frame.
class _NativeContractStackingEngine implements StackingEngineSeam {
  _NativeContractStackingEngine({this.filePattern});

  /// Bayer pattern the (file-path) native reader would report, or null for a
  /// mono frame / raw in-memory buffer (which carries no BAYERPAT).
  final String? filePattern;

  LiveStackingConfig? lastStartConfig;
  bool startedColor = false;
  int stopCount = 0;

  @override
  bool isActive() => false;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    required LiveStackingConfig config,
  }) async {
    // The file path can resolve a pattern from the frame's BAYERPAT geometry.
    _enforceContract(config, framePattern: filePattern);
    return const LiveStackingStats(stackedFrameCount: 1);
  }

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    required LiveStackingConfig config,
  }) async {
    // In-memory frames carry no BAYERPAT: only the config override can resolve
    // a pattern (mirrors `stacking_start_from_data`).
    _enforceContract(config, framePattern: null);
    return const LiveStackingStats(stackedFrameCount: 1);
  }

  void _enforceContract(
    LiveStackingConfig config, {
    required String? framePattern,
  }) {
    lastStartConfig = config;
    final mode = config.sensorMode.trim().toLowerCase();
    final resolved = config.bayerPattern ?? framePattern;
    switch (mode) {
      case 'mono':
        startedColor = false;
        return;
      case 'osc':
        if (resolved == null) {
          // Exactly the native error surface for OSC without a pattern.
          throw StateError('OSC declared but no Bayer pattern resolvable');
        }
        startedColor = true;
        return;
      case 'auto':
        startedColor = resolved != null;
        return;
      default:
        throw StateError("Unknown sensor mode '$mode'");
    }
  }

  @override
  Future<LinearFrameData> readLinearFrame(String filePath) async {
    return LinearFrameData(
      width: 2,
      height: 2,
      linearData: const [100.0, 200.0, 300.0, 400.0],
      bayerPattern: filePattern,
    );
  }

  @override
  Uint8List autoStretch({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) => Uint8List(width * height * 4);

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

/// A [LiveStackingService] stand-in that scripts the running stacked-frame
/// count per added follower, so the orchestrator's accept/reject accounting is
/// exercised deterministically. The reference is frame #1 (count 1); each
/// follower add returns the next scripted count.
class _FakeLiveStacking implements LiveStackingService {
  _FakeLiveStacking({required this.followerCounts, required this.finalResult});

  /// Stacked-frame count returned for each follower add, in order. A value that
  /// does not advance past the previous count marks that follower rejected.
  final List<int> followerCounts;

  /// The integrated result returned by [getCurrentResult].
  final LiveStackingResult finalResult;

  /// Ordered log of the per-frame add calls.
  final List<String> addCalls = <String>[];

  int _followerIndex = 0;

  @override
  Future<LiveStackingResult> addFrameFromFile(String imagePath) async {
    addCalls.add('addFile:$imagePath');
    return _nextResult();
  }

  @override
  Future<LiveStackingResult> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
  }) async {
    addCalls.add('addData:${width}x$height');
    return _nextResult();
  }

  LiveStackingResult _nextResult() {
    final count = followerCounts[_followerIndex];
    _followerIndex++;
    return LiveStackingResult(
      width: finalResult.width,
      height: finalResult.height,
      data: finalResult.data,
      stats: LiveStackingStats(stackedFrameCount: count),
    );
  }

  @override
  Future<LiveStackingResult> getCurrentResult() async => finalResult;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not used in this test',
  );
}

/// A [StackLightSelector] stand-in returning a scripted selection.
class _FakeSelector implements StackLightSelector {
  _FakeSelector(this.summary);

  final StackSelectionSummary summary;

  @override
  Future<StackSelectionSummary> selectForSession({
    required int sessionId,
    required StackAndShareConfig config,
  }) async => summary;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not used in this test',
  );
}

class _ControlledSelector implements StackLightSelector {
  final result = Completer<StackSelectionSummary>();

  @override
  Future<StackSelectionSummary> selectForSession({
    required int sessionId,
    required StackAndShareConfig config,
  }) => result.future;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not used in this test',
  );
}

class _MockBackend extends Mock implements SkotiqBackend {}

class _ReplaceableBackendNotifier extends BackendNotifier {
  _ReplaceableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void replaceWith(SkotiqBackend next) => state = next;
}

/// Build a selection with [followerCount] followers after a single reference.
/// Frame ids run 1..N; frame 1 is the reference. Paths are `/lights/N.fits`.
/// Every frame is a 60s exposure, so the selection-wide total and the per-frame
/// sum agree exactly the way the real selector makes them agree.
StackSelectionSummary _selection({
  required int followerCount,
  String filter = 'L',
  String targetName = 'M51',
}) {
  const exposureSecs = 60.0;
  final frames = <StackedFrameSelection>[
    StackedFrameSelection(
      imageId: 1,
      filePath: '/lights/1.fits',
      filter: filter,
      isReference: true,
      exposureSecs: exposureSecs,
    ),
    for (var i = 2; i <= followerCount + 1; i++)
      StackedFrameSelection(
        imageId: i,
        filePath: '/lights/$i.fits',
        filter: filter,
        exposureSecs: exposureSecs,
      ),
  ];
  return StackSelectionSummary(
    selected: frames,
    referencePath: '/lights/1.fits',
    perFilterCounts: {filter: frames.length},
    totalIntegrationSecs: frames.length * exposureSecs,
    targetName: targetName,
  );
}

/// Build an integrated result of the requested channel layout. A mono result
/// is one 2x2 luminance plane (4 samples); a colour result is interleaved
/// RGB16 (2x2x3 = 12 samples). The buffer length must match the channel count
/// or the orchestrator's layout guard rejects it.
LiveStackingResult _integrated({int stackedFrameCount = 3, int channels = 1}) =>
    LiveStackingResult(
      width: 2,
      height: 2,
      channels: channels,
      data: channels == 3
          ? const [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
          : const [10, 20, 30, 40],
      stats: LiveStackingStats(
        stackedFrameCount: stackedFrameCount,
        avgAlignmentResidual: 0.37,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late int sessionId;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    // Seed a session so getSessionById resolves. No targetId is set: a real
    // target row would need a foreign-key parent, and the orchestrator only
    // reads `session.targetId` straight through onto the result — the display
    // target *name* comes from the selector, which we fake.
    sessionId = await SessionsDao(db).startSession();
  });

  tearDown(() async {
    await db.close();
  });

  /// Build a provider container wiring the real DB, a fake selector, a fake
  /// live-stacking service, and (optionally) overriding the calibration /
  /// dark-library providers. Returns the container; the caller constructs the
  /// service with the injected [engine].
  ProviderContainer container({
    required StackSelectionSummary selection,
    required LiveStackingService liveStacking,
    List<Override> extra = const [],
  }) {
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        stackLightSelectorProvider.overrideWithValue(_FakeSelector(selection)),
        liveStackingServiceProvider.overrideWithValue(liveStacking),
        ...extra,
      ],
    );
  }

  group('busy guard', () {
    test(
      'throws LiveStackBusyException when the engine reports active',
      () async {
        final engine = _FakeStackingEngine(active: true);
        final c = container(
          selection: _selection(followerCount: 2),
          liveStacking: _FakeLiveStacking(
            followerCounts: const [2, 3],
            finalResult: _integrated(),
          ),
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        await expectLater(
          service.run(
            sessionId: sessionId,
            config: const StackAndShareConfig(applyCalibration: false),
          ),
          throwsA(isA<LiveStackBusyException>()),
        );
        // The guard fires before any engine work and before any stop: nothing
        // touches a singleton owned by the live session it refused to clobber.
        expect(engine.calls, isEmpty);
        expect(engine.stopCount, 0);
      },
    );

    test(
      'preparation is single-flight and a host switch discards the old run',
      () async {
        final oldBackend = _MockBackend();
        final newBackend = _MockBackend();
        final selector = _ControlledSelector();
        final live = _FakeLiveStacking(
          followerCounts: const [],
          finalResult: _integrated(stackedFrameCount: 1),
        );
        late _ReplaceableBackendNotifier backendNotifier;
        final c = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            stackLightSelectorProvider.overrideWithValue(selector),
            liveStackingServiceProvider.overrideWithValue(live),
            backendProvider.overrideWith((ref) {
              backendNotifier = _ReplaceableBackendNotifier(ref, oldBackend);
              return backendNotifier;
            }),
          ],
        );
        addTearDown(c.dispose);
        final engine = _FakeStackingEngine();
        final service = StackAndShareService(
          c.read(_refProvider),
          backend: oldBackend,
          engine: engine,
        );

        final first = service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(applyCalibration: false),
        );
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          service.run(
            sessionId: sessionId,
            config: const StackAndShareConfig(applyCalibration: false),
          ),
          throwsA(isA<LiveStackBusyException>()),
        );

        backendNotifier.replaceWith(newBackend);
        selector.result.complete(_selection(followerCount: 0));
        await expectLater(
          first,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('host changed'),
            ),
          ),
        );

        expect(engine.stopCount, 1);
        expect(live.addCalls, isEmpty);
        expect(
          await c.read(stackedResultsDaoProvider).getRecentResults(),
          isEmpty,
        );
      },
    );
  });

  group('happy path (calibration off → file path)', () {
    test(
      'processes the reference first, then followers in order, and stops',
      () async {
        final engine = _FakeStackingEngine();
        final live = _FakeLiveStacking(
          followerCounts: const [2, 3], // both followers accepted
          finalResult: _integrated(stackedFrameCount: 3),
        );
        final c = container(
          selection: _selection(followerCount: 2),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        final progress = <StackAndShareProgress>[];
        final result = await service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(
            applyCalibration: false,
            autoStretch: true,
          ),
          onProgress: progress.add,
        );

        // (b) The default config uses sensorMode 'auto', so the reference is
        // first read once for OSC discovery (it declares no Bayer pattern here, so
        // the run stays mono), then the reference (frame 1) starts the stack via
        // the FILE path, the two followers (frames 2, 3) are added via the file
        // path in order, the result is stretched, and the engine is stopped.
        expect(engine.calls, [
          'read:/lights/1.fits',
          'startFile:/lights/1.fits',
          'stretch',
          'stop',
        ]);
        expect(live.addCalls, [
          'addFile:/lights/2.fits',
          'addFile:/lights/3.fits',
        ]);

        // (d) Stop — not reset — was invoked exactly once so a later run is not
        // blocked by a wedged singleton.
        expect(engine.stopCount, 1);

        // Result provenance: target resolved from the seeded session, integration
        // from the selection, alignment residual + stacked count from the engine.
        expect(result.id, isNotNull);
        expect(result.targetId, isNull); // session was seeded with no target
        expect(result.targetName, 'M51'); // resolved by the selector
        expect(result.framesStacked, 3);
        expect(result.framesAttempted, 3);
        expect(result.integrationSecs, 180);
        expect(result.avgAlignmentResidual, closeTo(0.37, 1e-9));
        expect(result.filter, 'L');

        // The persisted row carries the same data, and the retained buffers are
        // exposed for the export step.
        final stored = await c
            .read(stackedResultsDaoProvider)
            .getResultById(result.id!);
        expect(stored, isNotNull);
        expect(service.lastRawResult, isNotNull);
        expect(
          service.lastRawResult!.data,
          Uint16List.fromList([10, 20, 30, 40]),
        );
        expect(service.lastRgbaResult, isNotNull); // auto-stretch ran

        // The terminal progress event is the success phase.
        expect(progress.last.phase, StackAndSharePhase.complete);
      },
    );

    test('auto-stretch off leaves the RGBA buffer unset', () async {
      final engine = _FakeStackingEngine();
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2),
        ),
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: false,
        ),
      );

      expect(engine.calls, isNot(contains('stretch')));
      expect(service.lastRawResult, isNotNull);
      expect(service.lastRgbaResult, isNull);
    });

    test('persists a viewer preview before reporting completion', () async {
      final engine = _FakeStackingEngine();
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2),
        ),
      );
      addTearDown(c.dispose);
      Uint8List? persistedRgba;
      final progress = <StackAndShareProgress>[];
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
        persistPreview: ({required result, required rgba}) async {
          expect(result.id, isNotNull);
          persistedRgba = Uint8List.fromList(rgba);
          return '/support/result_${result.id}.png';
        },
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: false,
        ),
        onProgress: progress.add,
      );

      expect(result.exportedImagePath, '/support/result_${result.id}.png');
      expect(persistedRgba, hasLength(16));
      expect(
        progress.map((event) => event.phase),
        contains(StackAndSharePhase.exporting),
      );
      expect(progress.last.phase, StackAndSharePhase.complete);
      // The preview gets a display STF, but autoStretch=false still leaves the
      // run's in-memory RGBA artifact unset.
      expect(engine.calls.where((call) => call == 'stretch'), hasLength(1));
      expect(service.lastRgbaResult, isNull);
    });

    test(
      'removes the metadata row when durable preview persistence fails',
      () async {
        final engine = _FakeStackingEngine();
        final c = container(
          selection: _selection(followerCount: 0),
          liveStacking: _FakeLiveStacking(
            followerCounts: const [],
            finalResult: _integrated(stackedFrameCount: 1),
          ),
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
          persistPreview: ({required result, required rgba}) async {
            throw const FileSystemException('disk full');
          },
        );

        await expectLater(
          service.run(
            sessionId: sessionId,
            config: const StackAndShareConfig(applyCalibration: false),
          ),
          throwsA(isA<FileSystemException>()),
        );

        expect(
          await c.read(stackedResultsDaoProvider).getRecentResults(),
          isEmpty,
        );
        expect(engine.stopCount, 1);
        expect(service.lastRawResult, isNull);
        expect(service.lastRgbaResult, isNull);
      },
    );
  });

  group('frame rejection accounting (c)', () {
    test(
      'framesRejected increments only when the stacked count does not advance',
      () async {
        final engine = _FakeStackingEngine();
        // Reference = count 1. Follower #2 advances to 2 (accepted). Follower #3
        // stays at 2 (rejected — alignment/pixel rejection). Follower #4 advances
        // to 3 (accepted).
        final live = _FakeLiveStacking(
          followerCounts: const [2, 2, 3],
          finalResult: _integrated(stackedFrameCount: 3),
        );
        final c = container(
          selection: _selection(followerCount: 3),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        final progress = <StackAndShareProgress>[];
        await service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(applyCalibration: false),
          onProgress: progress.add,
        );

        // Exactly one follower was rejected.
        final terminalStacking = progress.lastWhere(
          (p) => p.phase == StackAndSharePhase.stacking,
        );
        expect(terminalStacking.framesRejected, 1);
        expect(terminalStacking.framesProcessed, 4); // reference + 3 followers
      },
    );

    test('avgHfr is the mean HFR of the frames the engine integrated, not of '
        'every selected frame', () async {
      // captured_images ids 1..4 line up with the selection's frame ids.
      // Frame 3 is the one the engine refuses, and it is deliberately the
      // worst sub: if it leaked into the average the result would read 3.05
      // instead of 2.20.
      final images = ImagesDao(db);
      for (var i = 0; i < 4; i++) {
        const hfrs = [2.0, 2.4, 8.75, 2.2];
        await images.insertSequenceFrame(
          filePath: '/lights/${i + 1}.fits',
          fileName: '${i + 1}.fits',
          fileFormat: 'fits',
          exposureDuration: 60,
          capturedAt: DateTime.utc(2026, 7, 15),
          isAccepted: true,
          producingNodeId: 'node-1',
          sessionId: sessionId,
          hfr: hfrs[i],
        );
      }

      final engine = _FakeStackingEngine();
      // Reference (id 1) + followers 2 and 4 integrate; follower 3 does not
      // advance the count, so it is rejected.
      final live = _FakeLiveStacking(
        followerCounts: const [2, 2, 3],
        finalResult: _integrated(stackedFrameCount: 3),
      );
      final c = container(
        selection: _selection(followerCount: 3),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(applyCalibration: false),
      );

      expect(result.avgHfr, isNotNull);
      expect(result.avgHfr!, closeTo((2.0 + 2.4 + 2.2) / 3, 1e-9));

      // …and it is the PERSISTED value, so the result viewer's "Avg HFR" row
      // renders after a reopen rather than reading NULL out of the column.
      final persisted = await c
          .read(stackedResultsDaoProvider)
          .getResultById(result.id!);
      expect(persisted!.avgHfr, closeTo((2.0 + 2.4 + 2.2) / 3, 1e-9));
    });
  });

  group('release on failure (d)', () {
    // A frame the stacker refuses is a per-frame outcome, not a run-level
    // abort. The reproduced defect: with 8 subs and calibration off, the very
    // first follower was rejected for alignment residual, the Err escaped the
    // followers loop into the run-level catch, the partial stacked_results row
    // was deleted, and frames 3..8 were never attempted — one bad sub cost the
    // whole night. The framesRejected counter beside the await was unreachable.
    test(
      'a rejected follower is counted and skipped; the run continues',
      () async {
        final engine = _FakeStackingEngine();
        final live = _RejectingLiveStacking(
          rejectPaths: {'/lights/3.fits'},
          // Three followers accepted (2, 3, 4 of 5 attempted); frame 3 throws.
          followerCounts: const [2, 3, 4],
          finalResult: _integrated(stackedFrameCount: 4),
        );
        final c = container(
          selection: _selection(followerCount: 4),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        final progress = <StackAndShareProgress>[];
        final result = await service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(applyCalibration: false),
          onProgress: progress.add,
        );

        // Every follower after the rejected one was still attempted.
        expect(live.addCalls, [
          'addFile:/lights/2.fits',
          'addFile:/lights/3.fits',
          'addFile:/lights/4.fits',
          'addFile:/lights/5.fits',
        ]);
        // The run completed and persisted a real row.
        expect(progress.last.phase, StackAndSharePhase.complete);
        expect(result.id, isNotNull);
        expect(
          await c.read(stackedResultsDaoProvider).getResultById(result.id!),
          isNotNull,
        );
        // The rejection was counted, not swallowed.
        final stacking = progress
            .where((p) => p.phase == StackAndSharePhase.stacking)
            .toList();
        expect(stacking.last.framesRejected, 1);
        expect(stacking.last.framesProcessed, 5);

        // ...and the integration time describes the master that was built.
        // 5 subs x 60s were offered; the engine took 4, so the stack is 4
        // minutes, not 5. Quoting the selection-wide total here would overstate
        // every stack that rejected anything — on the result screen, in the
        // AstroBin sidecar and on the Share Card the user posts publicly.
        expect(result.integrationSecs, 240);
        expect(
          (await c.read(stackedResultsDaoProvider).getResultById(result.id!))!
              .integrationSecs,
          240,
          reason: 'the persisted row must carry the same honest total',
        );
      },
    );

    test('with nothing rejected the integration time is the whole '
        'selection', () async {
      // Guard against over-correcting: when the engine takes every sub, the
      // per-frame sum must still equal the selection-wide total.
      final engine = _FakeStackingEngine();
      final live = _FakeLiveStacking(
        followerCounts: const [2, 3, 4],
        finalResult: _integrated(stackedFrameCount: 4),
      );
      final c = container(
        selection: _selection(followerCount: 3),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(applyCalibration: false),
      );

      expect(result.integrationSecs, 240); // 4 subs x 60s, none refused
    });

    test(
      'a run whose followers are ALL rejected fails with the dominant reason '
      'instead of persisting a one-frame "stack"',
      () async {
        final engine = _FakeStackingEngine();
        final live = _RejectingLiveStacking(
          rejectPaths: {'/lights/2.fits', '/lights/3.fits'},
          followerCounts: const [],
          finalResult: _integrated(stackedFrameCount: 1),
        );
        final c = container(
          selection: _selection(followerCount: 2),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        await expectLater(
          service.run(
            sessionId: sessionId,
            config: const StackAndShareConfig(applyCalibration: false),
          ),
          throwsA(
            isA<StackAndShareAllFramesRejectedException>().having(
              (e) => e.dominantReason,
              'dominantReason',
              contains('Alignment residual too high'),
            ),
          ),
        );
        // Both followers were still attempted before the run gave up.
        expect(live.addCalls, [
          'addFile:/lights/2.fits',
          'addFile:/lights/3.fits',
        ]);
        expect(
          await c.read(stackedResultsDaoProvider).getRecentResults(),
          isEmpty,
        );
      },
    );

    test('stops the engine even when a mid-run step throws, and surfaces the '
        'original error', () async {
      // getCurrentResult throws after the frames are stacked: the finally must
      // still stop the engine, and the original error must propagate (not be
      // masked by the stop).
      final engine = _FakeStackingEngine();
      final live = _ThrowingLiveStacking(
        followerCounts: const [2],
        error: StateError('integration blew up'),
      );
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final progress = <StackAndShareProgress>[];
      await expectLater(
        service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(applyCalibration: false),
          onProgress: progress.add,
        ),
        throwsA(isA<StateError>()),
      );

      // The engine was stopped despite the failure.
      expect(engine.stopCount, 1);
      expect(engine.calls.last, 'stop');
      // The terminal progress event is the error phase, and retained buffers
      // are cleared so a failed run never exposes stale output.
      expect(progress.last.phase, StackAndSharePhase.error);
      expect(service.lastRawResult, isNull);
      expect(service.lastRgbaResult, isNull);
    });

    test(
      'a subsequent run succeeds because stop released the singleton',
      () async {
        // First run fails; because the finally called stop (not reset), the
        // engine reports inactive again and a second run passes the busy guard.
        final engine = _FakeStackingEngine();
        final failing = _ThrowingLiveStacking(
          followerCounts: const [2],
          error: StateError('first run failed'),
        );
        final c1 = container(
          selection: _selection(followerCount: 1),
          liveStacking: failing,
        );
        addTearDown(c1.dispose);
        final s1 = StackAndShareService(c1.read(_refProvider), engine: engine);
        await expectLater(
          s1.run(
            sessionId: sessionId,
            config: const StackAndShareConfig(applyCalibration: false),
          ),
          throwsA(isA<StateError>()),
        );

        // The fake engine's `active` flag was never flipped true by our fake (a
        // real stop sets the native guard to None), so a fresh service still sees
        // it inactive and runs to completion.
        expect(engine.isActive(), isFalse);

        final live2 = _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2),
        );
        final c2 = container(
          selection: _selection(followerCount: 1),
          liveStacking: live2,
        );
        addTearDown(c2.dispose);
        final s2 = StackAndShareService(c2.read(_refProvider), engine: engine);
        final result = await s2.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(applyCalibration: false),
        );
        expect(result.id, isNotNull);
        // Two runs → two stops.
        expect(engine.stopCount, 2);
      },
    );
  });

  group('calibration path split (e)', () {
    test(
      'calibration on uses the data path (readLinearFrame + startData)',
      () async {
        final engine = _FakeStackingEngine();
        final live = _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2),
        );
        // No dark/flat/bias is configured (the real in-memory DB has no
        // calibration settings), and the selection's image ids have no captured-
        // images rows, so the dark match resolves to none and `calibrateData`
        // becomes a pure pass-through. That still proves the DATA path is taken:
        // each frame's linear pixels are read and fed via startData / addData.
        final c = container(
          selection: _selection(followerCount: 1),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        await service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(
            applyCalibration: true,
            autoStretch: false,
          ),
        );

        // The reference is read + started via the DATA path, and the follower is
        // read + added via the DATA path. No file-path calls.
        expect(engine.calls, contains('read:/lights/1.fits'));
        expect(engine.calls, contains('startData:2x2'));
        expect(engine.calls.any((c) => c.startsWith('startFile')), isFalse);
        expect(live.addCalls, contains('addData:2x2'));
        expect(live.addCalls.any((c) => c.startsWith('addFile')), isFalse);
        expect(engine.stopCount, 1);
      },
    );
  });

  group('OSC / colour orchestration', () {
    test('mono regression: a mono result persists channels==1, isColor==false, '
        'and the single filter, with a grayscale stretch', () async {
      // The default fake engine reports no frame Bayer pattern and the fake
      // live result defaults to channels==1, so the historic mono path must be
      // byte-for-byte unchanged: filter 'L', mono raw result, grayscale stretch.
      final engine = _FakeStackingEngine();
      final live = _FakeLiveStacking(
        followerCounts: const [2],
        finalResult: _integrated(stackedFrameCount: 2), // channels: 1
      );
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: true,
          sensorMode: 'mono',
        ),
      );

      expect(result.channels, 1);
      expect(result.isColor, isFalse);
      expect(result.filter, 'L');
      expect(service.lastRawResult!.channels, 1);
      expect(service.lastRawResult!.isColor, isFalse);
      expect(
        service.lastRawResult!.data,
        Uint16List.fromList([10, 20, 30, 40]),
      );
      // Grayscale stretch route (channels == 1).
      expect(engine.lastStretchChannels, 1);
      // A mono run never reads the reference for a Bayer pattern (no discovery).
      expect(engine.calls.any((c) => c.startsWith('read:')), isFalse);
    });

    test('OSC via FITS BAYERPAT: a 3-channel result persists channels==3, '
        'isColor==true, filter OSC, and takes the per-channel stretch', () async {
      // auto mode + the reference frame declares a Bayer pattern → the resolved
      // engine config pins it, and the engine returns a 3-channel integration.
      final engine = _FakeStackingEngine(framePattern: 'RGGB');
      final live = _FakeLiveStacking(
        followerCounts: const [2],
        finalResult: _integrated(stackedFrameCount: 2, channels: 3),
      );
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: true,
          sensorMode: 'auto',
        ),
      );

      // (c) colour result assembly.
      expect(result.channels, 3);
      expect(result.isColor, isTrue);
      // (e) OSC stacks are labelled 'OSC', not the capture filter.
      expect(result.filter, 'OSC');
      expect(service.lastRawResult!.channels, 3);
      expect(service.lastRawResult!.isColor, isTrue);
      expect(service.lastRawResult!.data.length, 2 * 2 * 3);
      // (d) per-channel (unlinked) stretch route.
      expect(engine.lastStretchChannels, 3);

      // (a) the resolved Bayer pattern from the FITS geometry reached the
      // engine config at start.
      expect(engine.lastStartConfig, isNotNull);
      expect(engine.lastStartConfig!.sensorMode, 'auto');
      expect(engine.lastStartConfig!.bayerPattern, 'RGGB');

      // The persisted row carries the colour provenance.
      final stored = await c
          .read(stackedResultsDaoProvider)
          .getResultById(result.id!);
      expect(stored!.channels, 3);
      expect(stored.isColor, isTrue);
    });

    test('OSC via live camera capabilities: the connected colour camera\'s '
        'declared Bayer pattern wins over the frame geometry', () async {
      // The live camera advertises an OSC sensor (isColor + BGGR). Even though
      // the reference frame here declares RGGB, the camera caps take precedence
      // (the live path is preferred), and an explicit override is absent.
      final engine = _FakeStackingEngine(framePattern: 'RGGB');
      final live = _FakeLiveStacking(
        followerCounts: const [2],
        finalResult: _integrated(stackedFrameCount: 2, channels: 3),
      );
      const cameraId = 'native:zwo:0';
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
        extra: [
          connectedCameraIdProvider.overrideWithValue(cameraId),
          cameraCapabilitiesProvider(cameraId).overrideWith(
            (ref) async => const CameraCapabilities(
              maxWidth: 100,
              maxHeight: 100,
              bitDepth: 16,
              isColor: true,
              bayerPattern: 'BGGR',
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: false,
          sensorMode: 'auto',
        ),
      );

      expect(result.isColor, isTrue);
      expect(result.filter, 'OSC');
      // The camera's BGGR (live path) won over the frame's RGGB; the engine was
      // never asked to read the frame for a pattern.
      expect(engine.lastStartConfig!.bayerPattern, 'BGGR');
      expect(engine.calls.any((c) => c.startsWith('read:')), isFalse);
    });

    test(
      'explicit Bayer override wins over both camera caps and frame geometry',
      () async {
        final engine = _FakeStackingEngine(framePattern: 'RGGB');
        final live = _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2, channels: 3),
        );
        final c = container(
          selection: _selection(followerCount: 1),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        await service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(
            applyCalibration: false,
            autoStretch: false,
            sensorMode: 'osc',
            bayerPatternOverride: 'GRBG',
          ),
        );

        // The override pinned GRBG and short-circuited discovery (no frame read).
        expect(engine.lastStartConfig!.bayerPattern, 'GRBG');
        expect(engine.calls.any((c) => c.startsWith('read:')), isFalse);
      },
    );

    test('osc mode without any resolvable pattern throws a clear StateError '
        'and still releases the engine', () async {
      // sensorMode == osc, no override, no camera caps, and the frame declares
      // no Bayer geometry → debayering would scramble the mosaic, so the run
      // must refuse loudly rather than silently fall back to mono.
      final engine = _FakeStackingEngine(); // framePattern: null
      final live = _FakeLiveStacking(
        followerCounts: const [2],
        finalResult: _integrated(stackedFrameCount: 2, channels: 3),
      );
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      await expectLater(
        service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(
            applyCalibration: false,
            autoStretch: false,
            sensorMode: 'osc',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      // The resolution failure happens before the stack starts, but the
      // always-release finally must still leave the singleton free.
      expect(engine.stopCount, 1);
      expect(engine.calls.last, 'stop');
    });

    test(
      'auto mode without any resolvable pattern falls back to mono (no throw)',
      () async {
        // auto + no pattern anywhere → treat as mono: the engine simply will not
        // debayer. The result here reports channels==1, so it persists as mono.
        final engine = _FakeStackingEngine(); // framePattern: null
        final live = _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2), // channels: 1
        );
        final c = container(
          selection: _selection(followerCount: 1),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        final result = await service.run(
          sessionId: sessionId,
          config: const StackAndShareConfig(
            applyCalibration: false,
            autoStretch: false,
            sensorMode: 'auto',
          ),
        );

        expect(result.isColor, isFalse);
        expect(result.channels, 1);
        // No explicit pattern was pinned (left null → engine decides per-frame).
        expect(engine.lastStartConfig!.bayerPattern, isNull);
        expect(engine.lastStartConfig!.sensorMode, 'auto');
      },
    );
  });

  group('resolved config is accepted by the native sensor-mode contract', () {
    // These tests drive a seam that faithfully mirrors the native
    // `parse_sensor_mode` + OSC-without-pattern hard error, so the default
    // `auto` mono run (and its calibration-on twin) is proven to produce a
    // config the *real* backend accepts — not just one the lenient default fake
    // ignores. An auto/osc collapse here bricks every default mono
    // Stack-and-Share run against FfiBackend.
    test('default config (auto) on a mono frame starts as mono, not an error '
        '(calibration off → file path)', () async {
      final engine =
          _NativeContractStackingEngine(); // filePattern: null (mono)
      final live = _FakeLiveStacking(
        followerCounts: const [2],
        finalResult: _integrated(stackedFrameCount: 2), // channels: 1
      );
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      // The literal default config — auto + calibration on — but with
      // calibration forced off so this exercises the native file-start path.
      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: false,
        ),
      );

      expect(result.isColor, isFalse);
      expect(
        engine.startedColor,
        isFalse,
        reason: 'auto + mono frame must NOT debayer',
      );
      expect(engine.lastStartConfig!.sensorMode, 'auto');
    });

    test('auto on a frame that declares a Bayer pattern starts in colour '
        '(file path)', () async {
      // The complement to the mono case: when the reference frame's FITS
      // BAYERPAT geometry resolves a pattern, auto debayers — proving the
      // faithful seam is not simply forcing mono.
      final engine = _NativeContractStackingEngine(filePattern: 'RGGB');
      final live = _FakeLiveStacking(
        followerCounts: const [2],
        finalResult: _integrated(stackedFrameCount: 2, channels: 3),
      );
      final c = container(
        selection: _selection(followerCount: 1),
        liveStacking: live,
      );
      addTearDown(c.dispose);
      final service = StackAndShareService(
        c.read(_refProvider),
        engine: engine,
      );

      final result = await service.run(
        sessionId: sessionId,
        config: const StackAndShareConfig(
          applyCalibration: false,
          autoStretch: false,
        ),
      );

      expect(result.isColor, isTrue);
      expect(
        engine.startedColor,
        isTrue,
        reason: 'auto + CFA frame must debayer',
      );
      expect(engine.lastStartConfig!.sensorMode, 'auto');
    });

    test(
      'osc without a resolvable pattern is rejected by the contract seam',
      () async {
        // Cross-check: the same faithful seam *does* reject osc-without-pattern,
        // proving the auto-passes result above is not because the seam is lax.
        // (The service also guards this Dart-side, so the surfaced error is a
        // StateError either way.)
        final engine = _NativeContractStackingEngine(); // filePattern: null
        final live = _FakeLiveStacking(
          followerCounts: const [2],
          finalResult: _integrated(stackedFrameCount: 2, channels: 3),
        );
        final c = container(
          selection: _selection(followerCount: 1),
          liveStacking: live,
        );
        addTearDown(c.dispose);
        final service = StackAndShareService(
          c.read(_refProvider),
          engine: engine,
        );

        await expectLater(
          service.run(
            sessionId: sessionId,
            config: const StackAndShareConfig(
              applyCalibration: false,
              autoStretch: false,
              sensorMode: 'osc',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        expect(engine.stopCount, 1, reason: 'engine released on failure');
      },
    );
  });
}

/// A [LiveStackingService] fake whose [getCurrentResult] throws, used to prove
/// the finally still releases the engine on a mid-run failure.
/// Rejects the named follower paths the way the native stacker actually does —
/// by returning an `Err` that surfaces as a thrown `SkotiqError` — while
/// accepting the rest. Every rejection path in stacking.rs (too few stars, too
/// few matches, residual over the ceiling) behaves this way; none of them come
/// back as an `Ok` with an unadvanced stacked count.
class _RejectingLiveStacking extends _FakeLiveStacking {
  _RejectingLiveStacking({
    required this.rejectPaths,
    required super.followerCounts,
    required super.finalResult,
  });

  final Set<String> rejectPaths;

  @override
  Future<LiveStackingResult> addFrameFromFile(String imagePath) async {
    addCalls.add('addFile:$imagePath');
    if (rejectPaths.contains(imagePath)) {
      throw Exception(
        'SkotiqError.imageError(field0: Alignment residual too high: '
        '10.34px (max 10.00px))',
      );
    }
    return _nextResult();
  }
}

class _ThrowingLiveStacking extends _FakeLiveStacking {
  _ThrowingLiveStacking({required super.followerCounts, required this.error})
    : super(finalResult: _integrated());

  final Object error;

  @override
  Future<LiveStackingResult> getCurrentResult() async => throw error;
}

/// Exposes the enclosing container's [Ref] so services that take a `Ref` can be
/// constructed against the test overrides.
final _refProvider = Provider<Ref>((ref) => ref);
