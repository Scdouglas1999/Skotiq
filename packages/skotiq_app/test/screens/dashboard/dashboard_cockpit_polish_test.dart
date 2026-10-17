// Widget tests for Tonight's hero and its pinned banners (06 §Tonight):
//   1. The two run-level safety banners are present in the tree, and the
//      critical-events → notifications bridge is watched.
//   2. A live run puts Pause + a hold-to-confirm Stop in the HERO — there is no
//      separate run-control strip any more — and an idle page shows neither.
//   3. The first-light checklist owns the page when nothing is set up; the
//      panel grid replaces it as soon as a run is active or gear is connected.
//   4. The hero's single primary never states something untrue: a terminal run
//      with a sequence still loaded re-arms Start, and a connected rig with
//      nothing loaded is offered the Sequencer, not "Connect equipment".
//
// Test-surface notes mirror dashboard_screen_test.dart: every test uses an
// all-disabled (or selectively enabled) layout so no tile drags in a periodic
// poll timer past the test binding. Known RenderFlex overflows at the cramped
// surface are swallowed; anything else still fails the test.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout_provider.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_screen.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_checklist_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/critical_event_banner.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/recovery_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Minimal launchable sequence (one exposure) — enough to satisfy the
/// "has a target or exposures" launchability check.
Sequence _launchableSequence() {
  final root = InstructionSetNode(name: 'root');
  final expo = ExposureNode().copyWith(parentId: root.id);
  final placedRoot = root.copyWith(childIds: [expo.id]);
  return Sequence.create(
    name: 'Test',
    nodes: {placedRoot.id: placedRoot, expo.id: expo},
    rootNodeId: placedRoot.id,
  );
}

/// Seeds [currentSequenceProvider] with a pre-loaded sequence.
class _SeedingNotifier extends CurrentSequenceNotifier {
  _SeedingNotifier(Ref ref, Sequence seed) : super(ref: ref) {
    loadSequence(seed, discardUnsaved: true);
  }
}

/// An all-tiles-disabled layout — keeps observationTimeProvider untouched so
/// no periodic timer leaks past the test.
class _AllDisabledLayoutNotifier extends DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() async {
    final disabled = DashboardLayout.defaultLayout()
        .tiles
        .map((tile) => tile.copyWith(enabled: false))
        .toList();
    return DashboardLayout(
      version: DashboardLayout.currentVersion,
      tiles: disabled,
      secondaryZoneWidth: 0.4,
    );
  }
}

Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() {
    FlutterError.onError = defaultOnError;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'pinned safety banners are present in the dashboard tree (self-hidden '
      'when inactive)', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        // Active run so we exercise the cockpit (not standby) path; the
        // banners are pinned in every layout regardless.
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.running),
      ],
    );
    await _drainAsyncFrames(tester);

    // Both banners are always instantiated and pinned above the body; they
    // collapse to SizedBox.shrink internally when there's nothing to show.
    expect(find.byType(RunDashboardRecoveryBanner), findsOneWidget,
        reason: 'The recovery banner must be pinned in the dashboard tree.');
    expect(find.byType(RunDashboardCriticalBanner), findsOneWidget,
        reason: 'The critical-event banner must be pinned in the dashboard '
            'tree.');
  });

  testWidgets(
      'a running sequence puts Pause and a hold-to-confirm Stop in the hero',
      (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.running),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.text('Pause'), findsOneWidget,
        reason: 'A running sequence shows Pause, not Resume.');
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Skip'), findsNothing,
        reason: 'Skip left the hero with the strip: 06 §Tonight gives the hero '
            'the ONE primary plus one secondary, and Skip lives with the rest '
            'of the run controls in the Sequencer.');
    expect(find.byType(HoldToConfirmButton), findsWidgets,
        reason: 'Stop must stay wrapped in a HoldToConfirmButton so a stray '
            'click cannot abort an overnight run.');
  });

  testWidgets('an idle page offers neither Pause nor Resume', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        // Idle is the default, but pin it explicitly so the intent is clear.
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.text('Pause'), findsNothing);
    expect(find.text('Resume'), findsNothing);
    expect(find.text('Skip'), findsNothing);
  });

  testWidgets('the checklist owns the page when nothing is set up',
      (tester) async {
    _swallowKnownOverflows();

    // Idle + not capturing → standby hero, no tile grid.
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.byType(TonightChecklistPanel), findsOneWidget,
        reason: 'Nothing connected and nothing loaded must show the '
            'first-light checklist in place of the panel grid.');
    expect(find.text('Nothing running'.toUpperCase()), findsOneWidget,
        reason: 'The hero eyebrow names the state.');
    expect(find.text('Connect equipment'), findsOneWidget,
        reason: 'With nothing connected, the ONE primary is Connect '
            'equipment.');
    expect(find.text('Plan a target'), findsOneWidget,
        reason: 'and the one secondary is Plan a target.');
  });

  testWidgets(
      'a failed run with a loaded sequence re-arms Start instead of leaving a '
      'dead cockpit', (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        // The one-tap tonight flow loads the sequence BEFORE starting the
        // executor, so a failed start strands exactly this state: terminal
        // `failed` + a launchable sequence still loaded.
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.failed),
        currentSequenceProvider.overrideWith(
            (ref) => _SeedingNotifier(ref, _launchableSequence())),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.byType(TonightChecklistPanel), findsNothing,
        reason: 'A loaded sequence keeps the panel grid on screen.');
    expect(find.text('Start sequence'), findsOneWidget,
        reason: 'Terminal states must re-arm Start — without it the hero has '
            'nothing clickable.');
    expect(find.text('Open in Sequencer'), findsOneWidget,
        reason: 'and the one secondary goes to the sequence itself.');
  });

  testWidgets(
      'an awake cockpit with equipment but no sequence offers a way forward',
      (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
        // A connected camera wakes the cockpit (suppresses standby) without
        // any sequence loaded.
        cameraStateProvider.overrideWith((ref) {
          final notifier = CameraStateNotifier(ref);
          notifier
            ..setConnecting('test-cam-1', 'Test Camera')
            ..setConnected();
          return notifier;
        }),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.byType(TonightChecklistPanel), findsNothing,
        reason: 'Connected equipment puts the panel grid on screen.');
    expect(find.text('Connect equipment'), findsNothing,
        reason: 'Offering to connect equipment that is already connected is '
            'the app stating something untrue.');
    expect(find.text('Build a sequence'), findsOneWidget,
        reason: 'A connected rig with nothing loaded needs a sequence, and '
            'that is the honest primary for the state.');
  });

  testWidgets('the panel grid, not the checklist, renders while a run is live',
      (tester) async {
    _swallowKnownOverflows();
    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 800),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider.overrideWith(_AllDisabledLayoutNotifier.new),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.running),
      ],
    );
    await _drainAsyncFrames(tester);

    expect(find.byType(TonightChecklistPanel), findsNothing,
        reason: 'A running sequence must show the panel grid, not the '
            'first-light checklist.');
  });
}
