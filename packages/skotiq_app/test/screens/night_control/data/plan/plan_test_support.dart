// Shared inputs for the P1a plan data provider tests: a two-target plan, a
// fixed night over Boston, and a ProviderContainer whose every input is an
// override, so each test states exactly the rig, run and clock it means.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_night.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_core/skotiq_core_events.dart' as sk;

import '../../../../harness/harness.dart';

/// Boston, the site the boards are drawn for.
const LocationSettings boston = LocationSettings(
  latitude: 42.36,
  longitude: -71.06,
  elevation: 10,
);

/// The night of 2026-10-19 into the 20th, on the host's clock.
TonightNight bostonNight({required DateTime now}) => TonightNight(
      sunset: DateTime(2026, 10, 19, 18, 18),
      astroDark: DateTime(2026, 10, 19, 19, 48),
      astroDawn: DateTime(2026, 10, 20, 5, 44),
      sunrise: DateTime(2026, 10, 20, 7, 10),
      now: now,
      moonSet: DateTime(2026, 10, 19, 23, 9),
      moonIlluminationPercent: 44,
    );

/// A plan with two targets and a closing step:
///   M74:     L 3 × 60 s, dither every frame
///   NGC 891: Ha 2 × 120 s, dither every frame
///   Warm up
class TwoTargetPlan {
  TwoTargetPlan() {
    const rootId = 'root';
    m74 = TargetHeaderNode(
      id: 'm74',
      targetName: 'M74',
      raHours: 1.611,
      decDegrees: 15.783,
      parentId: rootId,
      childIds: const ['m74-l'],
      orderIndex: 0,
    );
    m74L = ExposureNode(
      id: 'm74-l',
      parentId: 'm74',
      filter: 'L',
      count: 3,
      durationSecs: 60,
      ditherEvery: 1,
    );
    ngc891 = TargetHeaderNode(
      id: 'ngc891',
      targetName: 'NGC 891',
      raHours: 2.376,
      decDegrees: 42.349,
      parentId: rootId,
      childIds: const ['ngc891-ha'],
      orderIndex: 1,
    );
    ngc891Ha = ExposureNode(
      id: 'ngc891-ha',
      parentId: 'ngc891',
      filter: 'Ha',
      count: 2,
      durationSecs: 120,
      ditherEvery: 1,
    );
    warm = WarmCameraNode(id: 'warm', parentId: rootId, orderIndex: 2);
    final root = InstructionSetNode(
      id: rootId,
      name: 'Tonight',
      childIds: const ['m74', 'ngc891', 'warm'],
    );
    sequence = Sequence.create(
      name: 'M74 plan',
      rootNodeId: rootId,
      nodes: {
        for (final node in <SequenceNode>[
          root,
          m74,
          m74L,
          ngc891,
          ngc891Ha,
          warm,
        ])
          node.id: node,
      },
    );
  }

  late final TargetHeaderNode m74;
  late final ExposureNode m74L;
  late final TargetHeaderNode ngc891;
  late final ExposureNode ngc891Ha;
  late final WarmCameraNode warm;
  late final Sequence sequence;
}

class _SeededSequence extends CurrentSequenceNotifier {
  // Seeded directly: loadSequence refuses while a run is live, and these
  // tests describe the plan a live run is executing.
  _SeededSequence(Ref ref, Sequence seed) : super(ref: ref) {
    state = seed;
  }
}

class _FixedProgress extends SequenceProgressNotifier {
  _FixedProgress(SequenceProgress seed) {
    state = seed;
  }
}

class _FixedSession extends SessionStateNotifier {
  _FixedSession(super.ref, SessionState seed) {
    state = seed;
  }
}

class _FixedHistory extends StateNotifier<List<sk.SkotiqEvent>>
    implements EventHistoryNotifier {
  _FixedHistory(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A NodeStarted / NodeCompleted event at [at].
sk.SkotiqEvent nodeEvent(
  String nodeId,
  DateTime at, {
  String? completedStatus,
}) {
  return sk.SkotiqEvent(
    eventId: BigInt.from(at.millisecondsSinceEpoch),
    timestamp: at.millisecondsSinceEpoch,
    severity: sk.EventSeverity.info,
    category: sk.EventCategory.sequencer,
    payload: sk.EventPayload.sequencer(
      completedStatus == null
          ? sk.SequencerEvent.nodeStarted(nodeId: nodeId, nodeType: 'x')
          : sk.SequencerEvent.nodeCompleted(
              nodeId: nodeId,
              status: completedStatus,
            ),
    ),
  );
}

/// A container with every P1a input pinned. Defaults: no plan, idle, camera
/// connected, commands allowed, Boston with the night above, meridian flips
/// off, the host's clock.
ProviderContainer planContainer({
  required DateTime now,
  Clock clock = const SystemClock(),
  Sequence? sequence,
  SequenceExecutionState execution = SequenceExecutionState.idle,
  SequenceProgress progress = const SequenceProgress(),
  SessionState session = const SessionState(),
  bool site = true,
  TonightNight? night,
  bool cameraConnected = true,
  bool canCommand = true,
  ManualActionState action = ManualActionState.idle,
  DateTime? armedStartAt,
  List<CapturedImage> sessionFrames = const [],
  List<sk.SkotiqEvent> events = const [],
  RunDashboardFilterTotals totals = RunDashboardFilterTotals.empty,
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, mockBackend()),
      ),
      inMemoryDatabaseOverride(),
      clockProvider.overrideWithValue(clock),
      nightNowProvider.overrideWithValue(now.toUtc()),
      tonightNightProvider.overrideWithValue(
        site ? (night ?? bostonNight(now: now)) : null,
      ),
      appObserverLocationProvider.overrideWithValue(site ? boston : null),
      effectiveHorizonDegProvider.overrideWithValue(30),
      sequencerOverheadConfigProvider.overrideWithValue(
        SequenceTimeEstimator.defaultEstimatorOverhead,
      ),
      isMeridianFlipEnabledProvider.overrideWithValue(false),
      currentSequenceProvider.overrideWith(
        (ref) => sequence == null
            ? CurrentSequenceNotifier(ref: ref)
            : _SeededSequence(ref, sequence),
      ),
      sequenceExecutionStateProvider.overrideWith((ref) => execution),
      sequenceProgressProvider.overrideWith((ref) => _FixedProgress(progress)),
      sessionStateProvider.overrideWith((ref) => _FixedSession(ref, session)),
      eventHistoryProvider.overrideWith((ref) => _FixedHistory(events)),
      recentSessionFramesProvider.overrideWithValue(sessionFrames),
      runDashboardFilterTotalsProvider.overrideWithValue(totals),
      nightCameraConnectedProvider.overrideWithValue(cameraConnected),
      backendCanCommandProvider.overrideWithValue(canCommand),
      nightPlanActionStateSeamProvider.overrideWithValue(action),
      nightPlanArmedStartSeamProvider.overrideWithValue(armedStartAt),
      ...extra,
    ],
  );
  return container;
}

/// One captured light frame in [filter].
CapturedImage lightFrame(String id, String filter, DateTime at) =>
    CapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      capturedAt: at,
      settings: ExposureSettings(
        exposureTime: 60,
        gain: 100,
        offset: 10,
        filter: filter,
      ),
    );
