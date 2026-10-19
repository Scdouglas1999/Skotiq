// Pumps the header and plan-column widgets with every provider they read
// overridden from the board fixtures, plus recording fakes for the run
// commands and the action controller.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/night_control/actions/night_action_controller.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_target_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_timeline_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_progress_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/plan_steps_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/upcoming_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';

/// Records the run commands instead of reaching an executor.
class RecordingSequenceActions extends SequenceActionService {
  RecordingSequenceActions(super.ref);

  final List<String> calls = <String>[];
  bool? stopPreservedCheckpoint;

  @override
  Future<CommandActionResult> start() async {
    calls.add('start');
    return CommandActionResult.ok;
  }

  @override
  Future<CommandActionResult> pause() async {
    calls.add('pause');
    return CommandActionResult.ok;
  }

  @override
  Future<CommandActionResult> resume() async {
    calls.add('resume');
    return CommandActionResult.ok;
  }

  @override
  Future<CommandActionResult> skip({bool showFeedback = true}) async {
    calls.add('skip');
    return CommandActionResult.ok;
  }

  @override
  Future<CommandActionResult> stop({bool preserveCheckpoint = true}) async {
    calls.add('stop');
    stopPreservedCheckpoint = preserveCheckpoint;
    return CommandActionResult.ok;
  }
}

/// Records what the header asks of the action controller.
class RecordingActionApi implements NightActionApi {
  final List<String> calls = <String>[];
  ManualActionState current = ManualActionState.idle;
  DateTime? armedAt;

  /// What [armStartAtDark] leaves in [state].
  NightText? armError;

  @override
  ManualActionState get state => current;

  @override
  DateTime? get armedStartAt => armedAt;

  @override
  Future<void> armStartAtDark() async {
    calls.add('arm');
    current = ManualActionState(phase: ManualActionPhase.idle, error: armError);
  }

  @override
  void cancelArmedStart() => calls.add('cancelArmed');

  @override
  Future<void> run(ManualActionId id) async => calls.add('run:$id');
  @override
  Future<void> snapshot() async => calls.add('snapshot');
  @override
  Future<void> toggleLoop() async => calls.add('loop');
  @override
  Future<void> autofocus() async => calls.add('autofocus');
  @override
  Future<void> solve() async => calls.add('solve');
  @override
  Future<void> solveAndSync() async => calls.add('solveAndSync');
  @override
  Future<void> center() async => calls.add('center');
  @override
  Future<void> dither() async => calls.add('dither');
  @override
  Future<void> flipNow() async => calls.add('flip');
  @override
  Future<void> toggleTracking() async => calls.add('tracking');
  @override
  Future<void> toggleCooler() async => calls.add('cooler');
  @override
  Future<void> cancel() async => calls.add('cancel');
}

/// Density for a widget pumped outside a [NightControlLayout].
NightControlDensity densityFor(
  NightControlMode mode, {
  required Widget child,
  VoidCallback? openPlanDrawer,
  double centerWidth = 744,
}) =>
    NightControlDensity(
      mode: mode,
      centerWidth: centerWidth,
      compactHeight: false,
      planDrawerOpen: false,
      openPlanDrawer: openPlanDrawer,
      closePlanDrawer: openPlanDrawer == null ? null : () {},
      child: child,
    );

/// The harness one test pumps: the fakes it can assert on and the router.
class NightHarness {
  NightHarness({
    required this.board,
    NightHeaderVm? header,
    NightTargetVm? target,
    this.noTarget = false,
    NightPlanVm? plan,
    this.noPlan = false,
    List<PlanStepVm>? steps,
    List<UpcomingItemVm>? upcoming,
  })  : header = header ?? board.header,
        target = target ?? board.target,
        plan = plan ?? board.plan,
        steps = steps ?? board.steps,
        upcoming = upcoming ?? board.upcoming;

  final NightBoard board;
  final NightHeaderVm header;
  final NightTargetVm? target;
  final bool noTarget;
  final NightPlanVm? plan;
  final bool noPlan;
  final List<PlanStepVm> steps;
  final List<UpcomingItemVm> upcoming;
  final RecordingActionApi api = RecordingActionApi();
  RecordingSequenceActions? actions;
  late final ProviderContainer container;
  late final GoRouter router;

  /// "Now" for the widgets, on the operator's clock.
  DateTime get now => board.timeline?.now ?? NightFixtures.at(23, 52);

  List<Override> overrides() => <Override>[
        clockProvider.overrideWithValue(const SystemClock()),
        nightNowProvider.overrideWithValue(now.toUtc()),
        nightRunPhaseProvider.overrideWithValue(header.phase),
        nightHeaderProvider.overrideWithValue(header),
        nightTimelineProvider.overrideWithValue(board.timeline),
        nightTargetProvider.overrideWithValue(noTarget ? null : target),
        nightPlanProgressProvider.overrideWithValue(noPlan ? null : plan),
        nightPlanStepsProvider.overrideWithValue(steps),
        nightUpcomingProvider.overrideWithValue(upcoming),
        nightActionApiProvider.overrideWithValue(api),
        nightActionStateProvider.overrideWithValue(board.actionState),
        sequenceActionServiceProvider.overrideWith(
          (ref) => actions = RecordingSequenceActions(ref),
        ),
      ];

  /// Pumps [child] at [size], with the text scaled by [textScale]. The
  /// child sits at the top of a page that also has a Sequencer route.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1316, 806),
    double textScale = 1,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);
    router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
              ),
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
        GoRoute(
          path: '/sequencer',
          builder: (context, state) => const Scaffold(body: Text('sequencer')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: theme ?? SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
  }
}

/// The board's header with [phase] and the controls the header provider
/// would publish for it.
NightHeaderVm headerFor(NightRunPhase phase, {ManualActionId? pausedFor}) {
  const on = NightControlVm.enabled();
  NightControlVm off(String key) => NightControlVm.disabled(NightText(key));
  final base = NightFixtures.header(
    switch (phase) {
      NightRunPhase.running ||
      NightRunPhase.pausedByUser ||
      NightRunPhase.pausedForAction ||
      NightRunPhase.stopping =>
        NightRunPhase.running,
      _ => NightRunPhase.ready,
    },
  );
  final live = base.phase == NightRunPhase.running;
  return NightHeaderVm(
    phase: phase,
    pausedFor: pausedFor,
    runStartedAt: base.runStartedAt,
    armedStartAt:
        phase == NightRunPhase.armed ? NightFixtures.at(19, 48) : null,
    planName: phase == NightRunPhase.notSetUp ? null : base.planName,
    targetIndex: base.targetIndex,
    targetCount: base.targetCount,
    stepIndex: base.stepIndex,
    stepCount: base.stepCount,
    currentFilter: base.currentFilter,
    currentExposureSecs: base.currentExposureSecs,
    framesDone: base.framesDone,
    framesTotal: base.framesTotal,
    plannedDuration: base.plannedDuration,
    pauseResume: switch (phase) {
      NightRunPhase.running || NightRunPhase.pausedByUser => on,
      NightRunPhase.pausedForAction => off('ncPlanActionOwnsResume'),
      NightRunPhase.stopping => off('ncPlanStopping'),
      _ => null,
    },
    skipStep: switch (phase) {
      NightRunPhase.running || NightRunPhase.pausedByUser => on,
      NightRunPhase.pausedForAction => off('ncPlanActionInProgress'),
      NightRunPhase.stopping => off('ncPlanStopping'),
      _ => null,
    },
    stop: live ? on : null,
    startNow: switch (phase) {
      NightRunPhase.notSetUp => off('ncPlanNoPlan'),
      NightRunPhase.ready ||
      NightRunPhase.armed ||
      NightRunPhase.finished =>
        on,
      _ => null,
    },
    startAtDark: switch (phase) {
      NightRunPhase.notSetUp => off('ncPlanNoPlan'),
      NightRunPhase.ready ||
      NightRunPhase.armed ||
      NightRunPhase.finished =>
        on,
      _ => null,
    },
  );
}
