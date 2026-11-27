// What every run-control surface offers in each run state: the Sequencer
// header (desktop), the phone builder's toolbar slot, the shell's mini bar and
// Tonight's header. One row per state; each cell lists the transport controls
// the surface shows, `+` pressable, `-` not, and for Tonight the reason a
// control gives when it cannot be pressed.
//
// A change to what a surface offers edits its row here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_header_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_plan_inputs.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mobile_playback_bar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/shell/widgets/running_sequence_mini_bar.dart';
import 'package:skotiq_app/services/night_actions/night_action_controller.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

Sequence _plan() {
  final root = InstructionSetNode(name: 'Root');
  final step = ExposureNode(name: 'Lum', durationSecs: 120, count: 20);
  return Sequence.create(
    name: 'Plan',
    nodes: {
      step.id: step.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [step.id]),
    },
    rootNodeId: root.id,
  );
}

class _ConnectedCamera extends CameraStateNotifier {
  _ConnectedCamera(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
    );
  }
}

/// The manual action controller paused the run for an autofocus.
const _autofocusHold = ManualActionState(
  phase: ManualActionPhase.running,
  active: ManualActionId.autofocus,
  startedRunPause: true,
);

class _State {
  const _State(
    this.name,
    this.lifecycle, {
    this.action = ManualActionState.idle,
    this.flip = false,
    this.canCommand = true,
    this.noHost = false,
    this.camera = true,
  });

  final String name;
  final SequenceExecutionState lifecycle;
  final ManualActionState action;
  final bool flip;
  final bool canCommand;
  final bool noHost;
  final bool camera;
}

const _states = <_State>[
  _State('idle', SequenceExecutionState.idle),
  _State('idle, camera off', SequenceExecutionState.idle, camera: false),
  _State('idle, no host', SequenceExecutionState.idle,
      noHost: true, canCommand: false),
  _State('idle, flip', SequenceExecutionState.idle, flip: true),
  _State('running', SequenceExecutionState.running),
  _State('paused by operator', SequenceExecutionState.paused),
  _State('paused by action hold', SequenceExecutionState.paused,
      action: _autofocusHold),
  _State('recovering', SequenceExecutionState.recovering),
  _State('stopping', SequenceExecutionState.stopping),
  _State('finalizing', SequenceExecutionState.finalizing),
  _State('stopFailed', SequenceExecutionState.stopFailed),
  _State('cleanupFailed', SequenceExecutionState.cleanupFailed),
  _State('completed', SequenceExecutionState.completed),
  _State('failed', SequenceExecutionState.failed),
  _State('running, linked without authority', SequenceExecutionState.running,
      canCommand: false),
];

/// state -> (Sequencer header, phone toolbar slot, mini bar, Tonight).
const _expected = <String, List<String>>{
  'idle': [
    'Fix 1 error+',
    'Start+',
    '',
    'Start at dark-(ncPlanNoSite) Start now+'
  ],
  'idle, camera off': [
    'Fix 2 errors+',
    'Start+',
    '',
    'Start at dark-(ncPlanConnectCamera) Start now-(ncPlanConnectCamera)'
  ],
  'idle, no host': [
    'Fix 1 error+',
    'Start+',
    '',
    'Start at dark-(ncPlanLinkComputer) Start now-(ncPlanLinkComputer)'
  ],
  'idle, flip': [
    'Fix 1 error+',
    'Start+',
    '',
    'Start at dark-(nightActBusyFlip) Start now-(nightActBusyFlip)'
  ],
  'running': [
    'Pause+ Stop+',
    'Pause+ Stop+ Skip+',
    'Pause+ Stop+ Skip+',
    'Pause+ Skip step+ Stop+'
  ],
  'paused by operator': [
    'Resume+ Stop+',
    'Resume+ Stop+ Skip+',
    'Resume+ Stop+ Skip+',
    'Resume+ Skip step+ Stop+'
  ],
  'paused by action hold': [
    'Resume- Stop+',
    'Resume- Stop+ Skip-',
    'Resume- Stop+ Skip-',
    'Resume-(ncPlanActionOwnsResume) Skip step-(ncPlanActionInProgress) Stop+'
  ],
  'recovering': [
    'Pause- Stop+',
    'Pause- Stop+ Skip-',
    'Pause- Stop+ Skip-',
    'Pause-(ncPlanRecovering) Skip step-(ncPlanRecovering) Stop+'
  ],
  'stopping': [
    'Pause- Stop+',
    'Pause- Stop+ Skip-',
    'Pause- Stop+ Skip-',
    'Pause-(ncPlanStopping) Skip step-(ncPlanStopping) Stop+'
  ],
  'finalizing': [
    'Pause- Stop-',
    'Pause- Stop- Skip-',
    'Pause- Stop- Skip-',
    'Pause-(ncPlanStopping) Skip step-(ncPlanStopping) Stop-(ncPlanFinalizing)'
  ],
  'stopFailed': [
    'Pause- Stop+',
    'Pause- Stop+ Skip-',
    'Pause- Stop+ Skip-',
    'Pause-(ncPlanStopping) Skip step-(ncPlanStopping) Stop+'
  ],
  'cleanupFailed': [
    'Pause- Stop+',
    'Pause- Stop+ Skip-',
    'Pause- Stop+ Skip-',
    'Pause-(ncPlanStopping) Skip step-(ncPlanStopping) Stop+'
  ],
  'completed': [
    'Fix 1 error+',
    'Start+',
    '',
    'Start at dark-(ncPlanNoSite) Start now+'
  ],
  'failed': [
    'Fix 1 error+',
    'Start+',
    '',
    'Start at dark-(ncPlanNoSite) Start now+'
  ],
  'running, linked without authority': [
    'Pause+ Stop+',
    'Pause+ Stop+ Skip+',
    'Pause+ Stop+ Skip+',
    'Pause-(ncPlanCannotCommand) Skip step-(ncPlanCannotCommand) Stop-(ncPlanCannotCommand)'
  ],
};

const _transportWords = {
  'Start',
  'Pause',
  'Resume',
  'Stop',
  'Skip',
  'Start now',
  'Start at dark',
  'Skip step',
};

bool _isTransport(String label) =>
    _transportWords.contains(label) || label.startsWith('Fix ');

bool _insideHold(WidgetTester tester, Element element) {
  var inside = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is HoldToConfirmButton) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// The transport controls under [region], in reading order.
String _cell(WidgetTester tester, Finder region) {
  if (region.evaluate().isEmpty) return '';
  final out = <(double, String)>[];
  for (final element in find
      .descendant(of: region, matching: find.byType(SkotiqButton))
      .evaluate()) {
    final button = element.widget as SkotiqButton;
    if (!_isTransport(button.label) || _insideHold(tester, element)) continue;
    final x = tester.getTopLeft(find.byWidget(button)).dx;
    out.add((x, '${button.label}${button.onPressed != null ? '+' : '-'}'));
  }
  for (final element in find
      .descendant(of: region, matching: find.byType(Tooltip))
      .evaluate()) {
    final tooltip = element.widget as Tooltip;
    final message = tooltip.message ?? '';
    if (!_isTransport(message) || _insideHold(tester, element)) continue;
    final inks = find.descendant(
      of: find.byWidget(tooltip),
      matching: find.byType(InkWell),
    );
    if (inks.evaluate().isEmpty) continue;
    final ink = inks.evaluate().first.widget as InkWell;
    final x = tester.getTopLeft(find.byWidget(tooltip)).dx;
    out.add((x, '$message${ink.onTap != null ? '+' : '-'}'));
  }
  for (final element in find
      .descendant(of: region, matching: find.byType(HoldToConfirmButton))
      .evaluate()) {
    final hold = element.widget as HoldToConfirmButton;
    final x = tester.getTopLeft(find.byWidget(hold)).dx;
    out.add((x, 'Stop${hold.enabled ? '+' : '-'}'));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out.map((e) => e.$2).join(' ');
}

String _tonight(NightHeaderVm header) {
  String one(String label, RunControl? control) {
    if (control == null) return '';
    if (control.enabled) return '$label+';
    return '$label-(${control.disabledReason?.key})';
  }

  final resume = header.phase == NightRunPhase.pausedByUser ||
      header.phase == NightRunPhase.pausedForAction;
  final armed = header.phase == NightRunPhase.armed;
  return [
    one(resume ? 'Resume' : 'Pause', header.pauseResume),
    one('Skip step', header.skipStep),
    one('Stop', header.stop),
    one(armed ? 'Cancel armed start' : 'Start at dark', header.startAtDark),
    one('Start now', header.startNow),
  ].where((s) => s.isNotEmpty).join(' ');
}

List<Override> _overrides(_State state) => [
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: state.lifecycle)),
      ),
      ledgerClockProvider.overrideWith(
        (ref) => const Stream<DateTime>.empty(),
      ),
      nightActionStateProvider.overrideWithValue(state.action),
      isFlipInProgressProvider.overrideWithValue(state.flip),
      nightNowProvider.overrideWithValue(DateTime.utc(2026, 10, 19, 22)),
      backendCanCommandProvider.overrideWithValue(state.canCommand),
      if (state.camera) cameraStateProvider.overrideWith(_ConnectedCamera.new),
      if (state.noHost)
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
        ),
    ];

Future<ProviderContainer> _pumpSequencer(
  WidgetTester tester,
  _State state,
  Size size,
) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _plan();
  final handle = await pumpAppScreen(
    tester,
    const SequencerScreen(),
    size: size,
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      ..._overrides(state),
    ],
  );
  await tester.pump(const Duration(milliseconds: 600));
  return handle.container;
}

void main() {
  final rows = <String, List<String>>{};

  for (final state in _states) {
    testWidgets('${state.name}: what each surface offers', (tester) async {
      DeviceTraits.debugOverride = DeviceTraits.desktop;
      final container = await _pumpSequencer(
        tester,
        state,
        const Size(1440, 900),
      );
      final header = _cell(tester, find.byType(PageHeader));
      final tonight = _tonight(container.read(nightHeaderProvider));

      DeviceTraits.debugOverride = DeviceTraits.phone;
      addTearDown(() => DeviceTraits.debugOverride = null);
      await _pumpSequencer(tester, state, const Size(390, 844));
      final phone = _cell(tester, find.byType(SequenceToolbar));
      expect(
        find.byType(MobilePlaybackBar).evaluate().length,
        lessThanOrEqualTo(1),
      );

      DeviceTraits.debugOverride = DeviceTraits.desktop;
      await pumpAppScreen(
        tester,
        RunningSequenceMiniBar(currentLocation: AppRoute.imaging.path),
        size: const Size(1440, 900),
        settle: false,
        extraOverrides: _overrides(state),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final mini = _cell(tester, find.byType(RunningSequenceMiniBar));

      rows[state.name] = [header, phone, mini, tonight];
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }

  tearDownAll(() {
    final table = StringBuffer();
    for (final entry in rows.entries) {
      table.writeln("  '${entry.key}': ["
          "${entry.value.map((c) => "'$c'").join(', ')}],");
    }
    // ignore: avoid_print
    print('RUN CONTROL TABLE\n$table');
  });

  test('the table', () {
    expect(rows.keys.toList(), _states.map((s) => s.name).toList());
    for (final state in _states) {
      expect(
        rows[state.name],
        _expected[state.name],
        reason: state.name,
      );
    }
  });
}
