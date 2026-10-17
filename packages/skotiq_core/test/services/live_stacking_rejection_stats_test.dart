// A refused frame is a COUNTED frame.
//
// Live finding ND-1: with Live Stacking running and the camera looping, the
// engine logged `Frame rejected: alignment residual 37.11px exceeds max
// 2.00px` for all 179 frames it was handed, while the panel sat at
// `Stacked Frames 1 · Total Attempted 1 · Rejected (Alignment) 0` for the
// whole six minutes. The engine had counted every one of those refusals
// (`total_frames_attempted` and `rejected_alignment_failures` are incremented
// BEFORE `add_frame` returns its error, see
// `native/skotiq_native/imaging/src/stacking.rs`), but the Dart side threw
// the error away, so the one readout that would have told the operator their
// match settings were rejecting everything never moved.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/live_stacking_provider.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockBackend extends Mock implements SkotiqBackend {}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// Stand-in stacker whose add-frame call refuses, exactly as the engine does
/// when the alignment residual exceeds the configured ceiling.
class _RefusingStacker implements LiveStackingService {
  _RefusingStacker(this.statsAfterRefusal);

  final LiveStackingStats statsAfterRefusal;
  int getStatsCalls = 0;

  @override
  Future<LiveStackingResult> addFrameFromFile(String imagePath) async {
    throw LiveStackingFrameRejected(
      reason: 'Alignment residual too high: 37.11px (max 2.00px)',
      stats: statsAfterRefusal,
    );
  }

  @override
  Future<LiveStackingStats> getStats() async {
    getStatsCalls++;
    return statsAfterRefusal;
  }

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async =>
      const LiveStackingStats(stackedFrameCount: 1, totalFramesAttempted: 1);

  @override
  Future<LiveStackingResult> getCurrentResult() async =>
      const LiveStackingResult(
        width: 2,
        height: 2,
        data: [0, 0, 0, 0],
        stats: LiveStackingStats(stackedFrameCount: 1, totalFramesAttempted: 1),
      );

  @override
  Future<void> stop() async {}

  @override
  Future<void> reset() async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const refused = LiveStackingStats(
    stackedFrameCount: 1,
    totalFramesAttempted: 180,
    rejectedAlignmentFailures: 179,
  );

  test(
    'a refused frame surfaces the engine tally instead of a bare error',
    () async {
      final remote = _MockNetworkBackend();
      when(() => remote.stackingAddFrame(any())).thenThrow(
        Exception('Alignment residual too high: 37.11px (max 2.00px)'),
      );
      when(() => remote.stackingGetStats()).thenAnswer((_) async => refused);

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, remote),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(liveStackingServiceProvider);

      await expectLater(
        service.addFrameFromFile('/tmp/frame.fits'),
        throwsA(
          isA<LiveStackingFrameRejected>()
              .having((e) => e.stats.totalFramesAttempted, 'attempted', 180)
              .having((e) => e.stats.rejectedAlignmentFailures, 'rejected', 179)
              .having((e) => e.toString(), 'message', contains('37.11px')),
        ),
      );
    },
  );

  test('the panel counters advance when every frame is refused', () async {
    final stacker = _RefusingStacker(refused);
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, _MockBackend()),
        ),
        liveStackingServiceProvider.overrideWithValue(stacker),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(liveStackingProvider.notifier);
    await notifier.startFromFile('/tmp/reference.fits');
    expect(container.read(liveStackingProvider).stats.stackedFrameCount, 1);

    await notifier.addFrameFromFile('/tmp/frame.fits');

    final stats = container.read(liveStackingProvider).stats;
    expect(
      stats.totalFramesAttempted,
      180,
      reason: 'the stacker attempted the frame; the panel must say so',
    );
    expect(
      stats.rejectedAlignmentFailures,
      179,
      reason: 'a session rejecting every frame must not read "Rejected 0"',
    );
    expect(stats.stackedFrameCount, 1);
  });
}
