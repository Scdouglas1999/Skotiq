// At ~900px the desktop builder auto-collapses its side panes so the canvas
// keeps a workable width. That collapse must stay overrulable: with an effective
// state of `userPref || derived`, clicking the toolbox icon three times and the
// properties icon once leaves the tree with no palette and no Target Settings —
// a window that can be read but not edited, with resizing as the only escape.
//
// A derived layout decision is a default. The operator's explicit tap is an
// instruction, and has to win.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final root = InstructionSetNode(name: 'Root');
  return Sequence.create(
    name: 'Narrow builder',
    rootNodeId: root.id,
    nodes: {
      exposure.id: exposure.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [exposure.id]),
    },
  );
}

List<Override> _overrides() {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
    // The ledger ETA clock is a real periodic stream; in the fake-async
    // zone its timer outlives every pump and fails teardown.
    ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ];
}

/// The collapsed pane's reopen affordance.
///
/// `find.byTooltip` no longer reaches it: the control is a
/// [SkotiqIconButton], which renders `SkotiqTooltip` (not Material's
/// `Tooltip`) and publishes its tooltip as the semantics label. Matching on the
/// widget keeps the test on the same control it always tested, by the same
/// name the user hovers.
Finder _paneToggle(String tooltip) => find.byWidgetPredicate(
      (widget) => widget is SkotiqIconButton && widget.tooltip == tooltip,
      description: 'SkotiqIconButton("$tooltip")',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The band where BOTH panes derive collapsed: the builder region is narrow
  // enough that even collapsing the toolbox leaves the canvas under its
  // comfortable width. A 900px WINDOW lands here once the nav rail and page
  // padding are taken out, which is what the live repro used; the test pumps
  // the screen at the region width directly so it does not depend on the shell.
  const narrowBuilder = Size(690, 900);

  testWidgets('both auto-collapsed panes can still be opened', (tester) async {
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: narrowBuilder,
      extraOverrides: _overrides(),
    );
    await tester.pumpAndSettle();

    // Precondition: the layout derived a collapse for BOTH panes (each is a
    // rail with a "Show …" affordance). If this stops holding, the width band
    // moved and the rest of the test is meaningless.
    expect(
      _paneToggle('Show Toolbox'),
      findsOneWidget,
      reason: 'expected the derived collapse here; the width band moved',
    );
    expect(_paneToggle('Show Properties'), findsOneWidget);

    await tester.tap(_paneToggle('Show Toolbox'));
    await tester.pumpAndSettle();
    expect(
      _paneToggle('Show Toolbox'),
      findsNothing,
      reason: 'one tap on the toolbox icon left the pane exactly as it was',
    );

    await tester.tap(_paneToggle('Show Properties'));
    await tester.pumpAndSettle();
    expect(
      _paneToggle('Show Properties'),
      findsNothing,
      reason: 'one tap on the properties icon left the pane exactly as it was',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a force-opened pane can be collapsed again', (tester) async {
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: narrowBuilder,
      extraOverrides: _overrides(),
    );
    await tester.pumpAndSettle();

    await tester.tap(_paneToggle('Show Toolbox'));
    await tester.pumpAndSettle();
    expect(_paneToggle('Show Toolbox'), findsNothing);

    // The panel header's own collapse control puts it back, and the override
    // must not immediately re-open it.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SequencerScreen)),
    );
    container.read(sequencerToolboxCollapsedProvider.notifier).state = true;
    container.read(sequencerToolboxForceOpenProvider.notifier).state = false;
    await tester.pumpAndSettle();

    expect(_paneToggle('Show Toolbox'), findsOneWidget);
  });
}
