// 2026-06-04 follow-up — live-stacking auto-feed during sequencer runs.
//
// Before this wiring, the Rust LiveStacking instruction node armed a
// broadcast session but nothing on the Dart side ever fed accepted frames
// into the stacker / LAN broadcast (see the single-frame OSC note in
// native/.../node/instructions/live_stacking.rs). The feature was inert in
// production: the broadcast served `{"active": false}` for the whole run.
//
// These tests verify the executor's FrameAccepted handler now:
//   1. arms the broadcast + starts the stacker on the FIRST accepted frame
//      (that frame becomes the reference automatically — no hand-picked
//      reference file), and
//   2. adds every SUBSEQUENT accepted frame to the existing stack and
//      republishes the rendered result to the broadcast, and
//   3. is a no-op when the running sequence has no LiveStacking node, and
//   4. fails LOUD (logs, does not silently feed) when an accepted frame
//      carries no save_path, and
//   5. tears the broadcast/stacker down when the sequence stops.

import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// In-memory fake of the native stacking engine. Records the frame paths
/// it was asked to stack so the test can assert the FIRST accepted frame
/// became the reference (via startFromFile) and later frames were added
/// (via addFrameFromFile). Returns a deterministic synthetic stack so the
/// notifier's preview (and therefore the broadcast publish) has real data.
class _FakeLiveStackingService implements LiveStackingService {
  final List<String> startedFrom = [];
  final List<String> addedFrames = [];
  bool stopped = false;
  int _frames = 0;

  static const int _w = 16;
  static const int _h = 12;

  // Not exercised by the autofeed flow; present to satisfy the interface.
  @override
  Uint8List autoStretchPreview({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) => Uint8List(width * height * 4);

  @override
  Future<LiveStackingMasterSave> saveMaster({required String filePath}) =>
      throw UnimplementedError('saveMaster is not part of the autofeed flow');

  List<int> _syntheticStack() {
    final out = Uint16List(_w * _h);
    for (var i = 0; i < out.length; i++) {
      out[i] = ((i + _frames) * 17) & 0xFFFF;
    }
    return out;
  }

  LiveStackingStats get _stats => LiveStackingStats(
    stackedFrameCount: _frames,
    totalFramesAttempted: _frames,
  );

  LiveStackingResult get _result => LiveStackingResult(
    width: _w,
    height: _h,
    data: _syntheticStack(),
    stats: _stats,
  );

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    startedFrom.add(referenceImagePath);
    _frames = 1;
    return _stats;
  }

  @override
  Future<LiveStackingStats> startArmed({
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    // Remote-only arm path; not exercised by the local autofeed executor test.
    return _stats;
  }

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    _frames = 1;
    return _stats;
  }

  @override
  Future<LiveStackingResult> addFrameFromFile(String imagePath) async {
    addedFrames.add(imagePath);
    _frames += 1;
    return _result;
  }

  @override
  Future<LiveStackingResult> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
  }) async {
    _frames += 1;
    return _result;
  }

  @override
  Future<LiveStackingResult> getCurrentResult() async => _result;

  @override
  Future<LiveStackingStats> getStats() async => _stats;

  @override
  Future<void> reset() async {
    _frames = 0;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    _frames = 0;
  }

  @override
  bool get isActive => _frames > 0;

  @override
  int get frameCount => _frames;
}

/// Build a runnable sequence: a root containing an enabled LiveStacking
/// node and an ExposureNode (so frame attribution resolves an exposure
/// duration). When [withLiveStacking] is false, only the exposure node is
/// present.
Sequence _sequenceWith({
  required bool withLiveStacking,
  bool liveStackingEnabled = true,
  int maxFrames = 0,
}) {
  final exposure = ExposureNode(
    id: 'exp-1',
    parentId: 'root',
    durationSecs: 120.0,
  );
  final nodes = <String, SequenceNode>{'exp-1': exposure};
  final childIds = <String>['exp-1'];
  if (withLiveStacking) {
    nodes['ls-1'] = LiveStackingNode(
      id: 'ls-1',
      parentId: 'root',
      isEnabled: liveStackingEnabled,
      stackMethod: LiveStackingMethod.sigma,
      broadcastPort: 8081,
      maxFramesToStack: maxFrames,
    );
    childIds.insert(0, 'ls-1');
  }
  final root = InstructionSetNode(id: 'root', name: 'Root');
  nodes['root'] = root.copyWith(childIds: childIds);
  return Sequence.create(
    name: 'Auto-feed test',
    rootNodeId: 'root',
    nodes: nodes,
  );
}

bridge_event.SkotiqEvent _frameAccepted({
  required String savePath,
  int frame = 1,
  double durationSecs = 120.0,
}) {
  return bridge_event.SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.info,
    category: bridge_event.EventCategory.sequencer,
    eventType: 'FrameAccepted',
    data: {
      'node_id': 'exp-1',
      'frame': frame,
      'total': 10,
      'accepted_total': frame,
      'rejected_total': 0,
      'duration_secs': durationSecs,
      if (savePath.isNotEmpty) 'save_path': savePath,
    },
  );
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late _FakeLiveStackingService fakeStacker;

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        // Never the real on-disk database: with several suites running at
        // once the shared file reports "database is locked" and the test
        // fails for a reason that has nothing to do with autofeed.
        databaseProvider.overrideWith((ref) {
          final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
          ref.onDispose(db.close);
          return db;
        }),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        liveStackingServiceProvider.overrideWithValue(fakeStacker),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    backend = MockBackend();
    fakeStacker = _FakeLiveStackingService();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await eventController.close();
  });

  // Drain the serialised feed chain + microtasks the auto-feed schedules.
  // Awaits the executor's real feed-chain tail rather than a wall-clock
  // margin, which races a slow runner and lets a still-running feed outlive
  // the test body ("failed after completion"). The trailing zero-delay turns
  // flush work the teardown path schedules off the chain (broadcast
  // deactivate).
  Future<void> settle(SequenceExecutor executor) async {
    await executor.liveStackingFeedSettledForTest;
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'first accepted frame arms broadcast and becomes the stack reference',
    () async {
      final container = buildContainer();
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(
            _sequenceWith(withLiveStacking: true),
            discardUnsaved: true,
          );
      final executor = container.read(sequenceExecutorProvider);

      executor.handleSequencerEventForTest(
        _frameAccepted(savePath: '/captures/m42/L_0001.fits'),
      );
      await settle(executor);

      // The first accepted frame must have started the stacker FROM THAT FILE
      // (auto reference) — not been added on top of a hand-picked reference.
      expect(
        fakeStacker.startedFrom,
        equals(['/captures/m42/L_0001.fits']),
        reason: 'first accepted frame must become the reference automatically',
      );
      expect(fakeStacker.addedFrames, isEmpty);

      // Broadcast armed + published the rendered reference stack.
      final broadcast = container.read(liveStackingBroadcastServiceProvider);
      expect(
        broadcast.state.active,
        isTrue,
        reason:
            'the broadcast must be armed by the auto-feed, not just by '
            'a manual UI action',
      );
      expect(broadcast.state.framesStacked, 1);
      expect(
        broadcast.state.integrationSecs,
        120.0,
        reason: 'integration must use the real exposure length, not a stub',
      );
      expect(broadcast.state.jpegBytes, isNotNull);
      expect(broadcast.state.jpegBytes![0], 0xFF);
      expect(broadcast.state.jpegBytes![1], 0xD8);
    },
  );

  test('subsequent accepted frames are added to the existing stack', () async {
    final container = buildContainer();
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWith(withLiveStacking: true),
          discardUnsaved: true,
        );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      _frameAccepted(savePath: '/captures/m42/L_0001.fits', frame: 1),
    );
    await settle(executor);
    executor.handleSequencerEventForTest(
      _frameAccepted(savePath: '/captures/m42/L_0002.fits', frame: 2),
    );
    executor.handleSequencerEventForTest(
      _frameAccepted(savePath: '/captures/m42/L_0003.fits', frame: 3),
    );
    await settle(executor);

    expect(
      fakeStacker.startedFrom,
      equals(['/captures/m42/L_0001.fits']),
      reason: 'only the FIRST frame starts/references the stack',
    );
    expect(
      fakeStacker.addedFrames,
      equals(['/captures/m42/L_0002.fits', '/captures/m42/L_0003.fits']),
    );

    final broadcast = container.read(liveStackingBroadcastServiceProvider);
    expect(
      broadcast.state.framesStacked,
      3,
      reason: 'the broadcast stack must grow without any manual step',
    );
    expect(broadcast.state.integrationSecs, 360.0);
  });

  test('no LiveStacking node => accepted frames are not auto-fed', () async {
    final container = buildContainer();
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWith(withLiveStacking: false),
          discardUnsaved: true,
        );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      _frameAccepted(savePath: '/captures/m42/L_0001.fits'),
    );
    await settle(executor);

    expect(fakeStacker.startedFrom, isEmpty);
    expect(fakeStacker.addedFrames, isEmpty);
    expect(
      container.read(liveStackingBroadcastServiceProvider).state.active,
      isFalse,
    );
  });

  test('disabled LiveStacking node => not auto-fed', () async {
    final container = buildContainer();
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWith(withLiveStacking: true, liveStackingEnabled: false),
          discardUnsaved: true,
        );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      _frameAccepted(savePath: '/captures/m42/L_0001.fits'),
    );
    await settle(executor);

    expect(fakeStacker.startedFrom, isEmpty);
    expect(
      container.read(liveStackingBroadcastServiceProvider).state.active,
      isFalse,
    );
  });

  test('accepted frame with no save_path is not fed (fails loud)', () async {
    final container = buildContainer();
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWith(withLiveStacking: true),
          discardUnsaved: true,
        );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(_frameAccepted(savePath: ''));
    await settle(executor);

    // The frame is NOT silently added — there is nothing to feed, and the
    // executor logged an error (verified by the absence of any stacker call;
    // a silent fallback would have invented a path).
    expect(fakeStacker.startedFrom, isEmpty);
    expect(fakeStacker.addedFrames, isEmpty);
    expect(
      container.read(liveStackingBroadcastServiceProvider).state.active,
      isFalse,
    );
  });

  test('frame cap stops adding frames past maxFramesToStack', () async {
    final container = buildContainer();
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWith(withLiveStacking: true, maxFrames: 2),
          discardUnsaved: true,
        );
    final executor = container.read(sequenceExecutorProvider);

    for (var i = 1; i <= 4; i++) {
      executor.handleSequencerEventForTest(
        _frameAccepted(savePath: '/captures/m42/L_000$i.fits', frame: i),
      );
      await settle(executor);
    }

    // Frame 1 = reference (start). Frame 2 = add (stack now has 2 == cap).
    // Frames 3 and 4 are over the cap and must NOT be added.
    expect(fakeStacker.startedFrom, hasLength(1));
    expect(
      fakeStacker.addedFrames,
      equals(['/captures/m42/L_0002.fits']),
      reason:
          'maxFramesToStack must bound the stack; frames over the cap '
          'are dropped from the stack rather than unbounded-growing',
    );
  });

  test('stop() tears down the broadcast and stacker', () async {
    final container = buildContainer();
    container
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          _sequenceWith(withLiveStacking: true),
          discardUnsaved: true,
        );
    final executor = container.read(sequenceExecutorProvider);

    executor.handleSequencerEventForTest(
      _frameAccepted(savePath: '/captures/m42/L_0001.fits'),
    );
    await settle(executor);
    expect(
      container.read(liveStackingBroadcastServiceProvider).state.active,
      isTrue,
    );

    // A Stopped event (the path a natural completion / user-stop takes
    // through the event stream) must tear the broadcast down.
    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'Stopped',
        data: const {},
      ),
    );
    await settle(executor);

    expect(
      container.read(liveStackingBroadcastServiceProvider).state.active,
      isFalse,
      reason: 'a stopped run must not keep serving a stale broadcast',
    );
    expect(fakeStacker.stopped, isTrue);
  });
}
