// The toolbar's "Slew to Target" must not fire a real, unconfirmed slew —
// during a run, or to a target below the horizon — with zero feedback: no
// dialog, no toast, no "Slewing" state, and nothing in the session log, so the
// only way to discover the mount moved is to open another screen and read the
// Equipment panel.
//
// These tests drive the real toolbar: the control must be locked while the
// executor owns the mount, and must ask before moving it when idle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

Sequence _sequenceWithTarget() {
  final exposure = ExposureNode(
    id: 'exp',
    name: 'Lum',
    durationSecs: 15,
    count: 4,
    parentId: 'target',
  );
  final target = TargetHeaderNode(
    id: 'target',
    name: 'Target',
    targetName: 'M42-TEST',
    raHours: 12.0,
    decDegrees: -35.0,
    childIds: const ['exp'],
  );
  return Sequence.create(
    name: 'T',
    nodes: {target.id: target, exposure.id: exposure},
    rootNodeId: target.id,
  );
}

Future<void> _pumpToolbar(
  WidgetTester tester, {
  required SequenceExecutionState executionState,
}) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _sequenceWithTarget();

  await pumpAppScreen(
    tester,
    Builder(
      builder: (context) =>
          SequenceToolbar(colors: SkotiqColors.of(context)),
    ),
    size: const Size(1600, 900),
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider.overrideWith((ref) => executionState),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('locked while the sequence is running, like its neighbours',
      (tester) async {
    await _pumpToolbar(tester, executionState: SequenceExecutionState.running);

    await openCanvasBarMenu(tester);
    const locked = 'Slew to target (locked while sequence is running)';
    expect(canvasBarAction(locked), findsOneWidget);
    expect(canvasBarAction('Slew to target'), findsNothing);
    expect(
      canvasBarActionEnabled(tester, locked),
      isFalse,
      reason: 'a mount command during a run fights the executor for the '
          'telescope',
    );
  });

  testWidgets('when idle it asks before moving the mount', (tester) async {
    await _pumpToolbar(tester, executionState: SequenceExecutionState.idle);

    await tapCanvasBarAction(tester, 'Slew to target');

    expect(find.text('Slew to M42-TEST?'), findsOneWidget);
    expect(find.text('The mount will move now.'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Slew now'), findsOneWidget);
  });
}
