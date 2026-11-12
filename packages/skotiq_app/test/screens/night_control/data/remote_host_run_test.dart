// Tonight on a client linked to a host that already has a run (sync night
// 2026-11-03): SY-01 (joined after the run), SY-25 (restarted during a paused
// run), SY-37 (the run ended while the client watched). The host is faked by
// its rows and by the run record it publishes through the runtime mirror.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_progress_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_stats_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

import 'plan/plan_test_support.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

_MockNetworkBackend _link() {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.getHostNightHistory()).thenAnswer((_) async => null);
  return backend;
}

db.CapturedImage _row(
  int id,
  int sessionId,
  DateTime at, {
  String filter = 'L',
  String type = 'light',
  bool accepted = true,
}) =>
    db.CapturedImage(
      id: id,
      filePath: 'C:/Users/scdou/Documents/frame_$id.fits',
      fileName: 'frame_$id.fits',
      fileFormat: 'fits',
      binX: 1,
      binY: 1,
      sessionId: sessionId,
      frameType: type,
      filter: filter,
      exposureDuration: 60,
      hfr: 1.8,
      starCount: 150,
      capturedAt: at,
      isAccepted: accepted,
      isPlateSolved: false,
      createdAt: at,
    );

db.ImagingSession _session(int id, DateTime start, String status) =>
    db.ImagingSession(
      id: id,
      startTime: start,
      status: status,
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
    );

/// The host's id for the plan the client shows. A plan's id is made where the
/// plan is opened, so it is never the client's id for the same plan.
const _hostPlanId = 'the-plan-as-the-host-opened-it';

/// Apply what the host's runtime mirror publishes for its run record.
void _hostRecord(
  ProviderContainer client,
  NetworkBackend backend, {
  SequenceTerminalRunResult? terminal,
  CompletedImagingRun? imagingRun,
  LastEndedRun? lastEnded,
  bool lastEndedPlanLoaded = true,
  SequenceStopDecision? stopEvidence,
  DateTime? runStartedAt,
}) {
  applyHostRuntimeUpdate(
    client,
    HostRuntimeUpdate(
      channel: runRecordChannelKey,
      revision: DateTime.now().microsecondsSinceEpoch,
      value: const RunRecordChannel().encode((
        terminal: terminal,
        imagingRun: imagingRun,
        lastEnded: lastEnded,
        lastEndedPlanLoaded: lastEnded != null && lastEndedPlanLoaded,
        stopEvidence: stopEvidence,
        runStartedAt: runStartedAt,
      )),
    ),
    networkBackend: backend,
  );
}

Future<void> _settle(
    ProviderContainer c, List<ProviderListenable<Object?>> ps) async {
  for (final p in ps) {
    c.listen(p, (_, __) {});
  }
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SequenceRunStats _stats(int frames, int rejected) {
  final stats = SequenceRunStats();
  for (var i = 0; i < frames; i++) {
    stats.recordFrame(
      target: 'M74',
      filter: 'L',
      exposureSecs: 60,
      accepted: i >= rejected,
    );
  }
  stats.autofocusRuns = 1;
  stats.ditherCount = 3;
  return stats;
}

void main() {
  final evening = DateTime(2026, 10, 19, 20, 10);

  test('SY-01: a client that joins after the run shows the finished night',
      () async {
    final plan = TwoTargetPlan();
    final runStart = DateTime(2026, 10, 19, 19, 50);
    final rows = <db.CapturedImage>[
      for (var i = 0; i < 3; i++)
        _row(500 + i, 113, runStart.add(Duration(minutes: 2 + i))),
      for (var i = 0; i < 2; i++)
        _row(510 + i, 113, runStart.add(Duration(minutes: 8 + i)),
            filter: 'Ha'),
      // The end-of-night darks that ran after it, in their own session.
      for (var i = 0; i < 3; i++)
        _row(520 + i, 114, runStart.add(Duration(minutes: 20 + i)),
            filter: 'DARK', type: 'dark'),
    ];
    final backend = _link();
    final client = planContainer(
      now: evening,
      sequence: plan.sequence,
      backend: backend,
      extra: [
        allDbImagesProvider.overrideWith((ref) => Stream.value(rows)),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value([
            _session(
                114, runStart.add(const Duration(minutes: 19)), 'cancelled'),
            _session(113, runStart, 'completed'),
          ]),
        ),
      ],
    );
    addTearDown(client.dispose);
    client.read(lastEndedRunProvider);

    const imaging = SequenceTerminalRunResult(
      generation: 4,
      outcome: SequenceExecutionState.completed,
      runStatus: 'completed',
      runId: 41,
      dbSessionId: 113,
    );
    _hostRecord(
      client,
      backend,
      terminal: const SequenceTerminalRunResult(
        generation: 5,
        outcome: SequenceExecutionState.idle,
        runStatus: 'stopped',
        runId: 42,
        dbSessionId: 114,
        isCalibration: true,
      ),
      imagingRun: CompletedImagingRun(imaging, _stats(5, 1)),
      lastEnded: LastEndedRun(
        sequenceId: _hostPlanId,
        endedAt: runStart.add(const Duration(minutes: 22)),
      ),
      runStartedAt: runStart.add(const Duration(minutes: 19)),
    );
    await _settle(client, [
      nightSessionFramesProvider,
      nightPlanProgressProvider,
      nightSessionStatsProvider,
      nightFrameSeriesProvider,
    ]);

    expect(client.read(nightRunPhaseProvider), NightRunPhase.finished);
    expect(client.read(nightSessionIdProvider), 113);
    expect(client.read(nightSessionFramesProvider), hasLength(5));
    expect(client.read(nightFrameSeriesProvider).sampleCount, 5);
    final stats = client.read(nightSessionStatsProvider);
    expect(stats.frameCount, 5);
    final plan0 = client.read(nightPlanProgressProvider)!;
    expect(
      {for (final row in plan0.rows) row.filter: row.framesDone},
      {'L': 3, 'Ha': 2},
    );
  });

  test('a run the host ended for another plan does not finish the plan this '
      'client shows', () async {
    final plan = TwoTargetPlan();
    final backend = _link();
    final client = planContainer(
      now: evening,
      sequence: plan.sequence,
      backend: backend,
    );
    addTearDown(client.dispose);
    client.read(lastEndedRunProvider);

    LastEndedRun ended() => LastEndedRun(
          sequenceId: _hostPlanId,
          endedAt: DateTime(2026, 10, 19, 20, 5),
        );
    _hostRecord(client, backend, lastEnded: ended());
    expect(client.read(nightRunPhaseProvider), NightRunPhase.finished);

    // Nothing here says who ended it: the host's record does.
    expect(client.read(nightHeaderProvider).ending, NightRunEnding.ended);
    _hostRecord(
      client,
      backend,
      lastEnded: ended(),
      stopEvidence: const SequenceStopDecision(SequenceStopAuthor.operatorPress),
    );
    expect(client.read(nightHeaderProvider).ending, NightRunEnding.stopped);

    // The host has since opened another plan.
    _hostRecord(client, backend, lastEnded: ended(), lastEndedPlanLoaded: false);
    expect(client.read(nightRunPhaseProvider), isNot(NightRunPhase.finished));
  });

  test('SY-25: a client restarted during a paused run counts the run frames',
      () async {
    final plan = TwoTargetPlan();
    final runStart = DateTime(2026, 10, 19, 19, 50);
    // The client came back 75 minutes into the run, after a failed flip.
    final now = runStart.add(const Duration(minutes: 75));
    final rows = <db.CapturedImage>[
      for (var i = 0; i < 3; i++)
        _row(600 + i, 120, runStart.add(Duration(minutes: 2 + i))),
    ];
    final backend = _link();
    final client = planContainer(
      now: now,
      sequence: plan.sequence,
      backend: backend,
      execution: SequenceExecutionState.paused,
      session: SessionState(
        isActive: true,
        startTime: runStart,
        dbSessionId: 120,
      ),
      progress: const SequenceProgress(
        state: SequenceExecutionState.paused,
        currentNodeId: 'm74-l',
        nodeStatuses: {'m74': NodeStatus.running, 'm74-l': NodeStatus.running},
      ),
      // What this client saw arrive since it restarted: nothing.
      sessionFrames: const [],
      extra: [
        allDbImagesProvider.overrideWith((ref) => Stream.value(rows)),
        // The start as a client that missed it records it: when it joined.
        runStartedAtProvider.overrideWith((ref) => now),
      ],
    );
    addTearDown(client.dispose);
    await _settle(client, [nightPlanProgressProvider]);

    final progress = client.read(nightPlanProgressProvider)!;
    final l = progress.rows.firstWhere((row) => row.filter == 'L');
    expect(l.framesDone, 3, reason: 'the host has 3 frames of this run');
    expect(l.integrated, const Duration(minutes: 3));
    // The plan's estimate ran out long ago; the ETA and the steps still to
    // run are not times already gone.
    expect(progress.eta, isNotNull);
    expect(progress.eta!.isBefore(now), isFalse);
    final steps = client.read(nightPlanStepsProvider);
    final warm = steps.firstWhere((s) => s.nodeId == plan.warm.id);
    final at = (warm.when! as StepWhenPlanned).at;
    expect(at.isBefore(now), isFalse);
  });

  test('SY-37: at the run end the frame views keep the run', () async {
    final plan = TwoTargetPlan();
    final runStart = DateTime(2026, 10, 19, 19, 50);
    final rows = <db.CapturedImage>[
      for (var i = 0; i < 3; i++)
        _row(700 + i, 130, runStart.add(Duration(minutes: 2 + i)),
            accepted: i != 1),
    ];
    final backend = _link();
    final client = planContainer(
      now: evening,
      sequence: plan.sequence,
      backend: backend,
      // The host ended the run as failed and closed its session.
      execution: SequenceExecutionState.failed,
      progress: const SequenceProgress(
        state: SequenceExecutionState.failed,
        nodeStatuses: {
          'm74': NodeStatus.success,
          'm74-l': NodeStatus.success,
          'ngc891': NodeStatus.failure,
        },
      ),
      extra: [
        allDbImagesProvider.overrideWith((ref) => Stream.value(rows)),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value([_session(130, runStart, 'completed')]),
        ),
      ],
    );
    addTearDown(client.dispose);
    const result = SequenceTerminalRunResult(
      generation: 7,
      outcome: SequenceExecutionState.failed,
      runStatus: 'failed',
      runId: 50,
      dbSessionId: 130,
    );
    _hostRecord(
      client,
      backend,
      terminal: result,
      imagingRun: CompletedImagingRun(result, _stats(3, 1)),
      lastEnded: LastEndedRun(
        sequenceId: _hostPlanId,
        endedAt: runStart.add(const Duration(minutes: 10)),
      ),
      runStartedAt: runStart,
    );
    await _settle(client, [
      nightSessionFramesProvider,
      nightPlanProgressProvider,
      nightFrameSeriesProvider,
      nightTemperatureSeriesProvider,
    ]);

    expect(client.read(nightRunPhaseProvider), NightRunPhase.finished);
    expect(client.read(nightSessionFramesProvider), hasLength(3));
    expect(client.read(nightFrameSeriesProvider).sampleCount, 3);
    expect(client.read(nightTemperatureSeriesProvider).sampleCount, 3);
    final l = client
        .read(nightPlanProgressProvider)!
        .rows
        .firstWhere((row) => row.filter == 'L');
    expect(l.framesDone, 3);
    // A step that ran and has no recorded time shows none, not an estimate.
    final done = client
        .read(nightPlanStepsProvider)
        .firstWhere((s) => s.nodeId == plan.m74L.id);
    expect(done.status, PlanStepStatus.done);
    expect(done.when, isNull);
  });

  // Owner, 2026-11-08: a crash or an update mid-night must not start the
  // night over. The restored run opens a new session on the host.
  test('a host restarted mid-night: the client lists the whole night, the '
      'plan counts the restored run', () async {
    final plan = TwoTargetPlan();
    final runStart = DateTime(2026, 11, 7, 21, 10);
    final restored = DateTime(2026, 11, 8, 0, 40);
    final rows = <db.CapturedImage>[
      for (var i = 0; i < 3; i++)
        _row(700 + i, 130, runStart.add(Duration(minutes: 3 * i))),
      for (var i = 0; i < 2; i++)
        _row(710 + i, 131, restored.add(Duration(minutes: 3 * i))),
      // The night before: not tonight's.
      _row(600, 129, DateTime(2026, 11, 6, 23)),
    ];
    final backend = _link();
    final client = planContainer(
      now: restored.add(const Duration(minutes: 10)),
      sequence: plan.sequence,
      backend: backend,
      extra: [
        allDbImagesProvider.overrideWith((ref) => Stream.value(rows)),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value([
            _session(131, restored, 'active'),
            _session(130, runStart, 'interrupted'),
            _session(129, DateTime(2026, 11, 6, 22), 'completed'),
          ]),
        ),
      ],
    );
    addTearDown(client.dispose);
    await _settle(client, [
      nightSessionFramesProvider,
      nightSessionStatsProvider,
      nightFrameSeriesProvider,
    ]);

    expect(client.read(nightSessionIdProvider), 131);
    final frames = client.read(nightSessionFramesProvider);
    expect(frames.map((f) => f.id), [700, 701, 702, 710, 711]);
    expect(frames.last.frameNumber, 5);
    expect(client.read(nightFrameSeriesProvider).sampleCount, 5);
    expect(client.read(nightSessionStatsProvider).frameCount, 5);
    expect(client.read(nightRunLightRowsProvider), hasLength(2));
  });
}
