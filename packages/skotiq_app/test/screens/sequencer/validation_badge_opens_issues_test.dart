// The canvas bar's red/amber count chips must be readable without arming a run.
//
// They were plain Containers: clicking did nothing, the builder has no issues
// panel, and the only way to learn what "1 error" meant was to press Start and
// read the pre-flight dialog. That is a real hazard at 2am - "press the button
// that starts the rig" is not an acceptable way to ask "what's wrong?".
//
// The assertions below deliberately read the LIVE validation state and then
// require the dialog to show every issue in it, rather than hard-coding rule
// text: the property under test is "the badge opens the same issue list",
// not "this particular rule fires".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_issues_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tapping the validation badge opens the issue list',
      (tester) async {
    // A target still carrying the (0h, +0deg) placeholder: a real rule fires
    // on it AND names the offending node, so both halves are exercised.
    final target = TargetHeaderNode(
      targetName: 'Unset target',
      raHours: 0,
      decDegrees: 0,
    );
    final root = InstructionSetNode(name: 'Root');
    final editor = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    editor.state = Sequence.create(
      name: 'Tonight',
      nodes: {
        target.id: target.copyWith(parentId: root.id),
        root.id: root.copyWith(childIds: [target.id]),
      },
      rootNodeId: root.id,
    );

    final handle = await pumpAppScreen(
      tester,
      // The counts moved from the tree's own header row to the canvas bar
      // in wave 3 (06 §Sequencer), so the pair is pumped together — which is
      // also how the builder lays them out.
      Builder(
        builder: (context) => Column(
          children: [
            SequenceToolbar(colors: SkotiqColors.of(context)),
            Expanded(
              child: SequenceTree(colors: SkotiqColors.of(context)),
            ),
          ],
        ),
      ),
      size: const Size(1000, 800),
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => editor),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
        // The ledger ETA clock is a real periodic stream; in the fake-async
        // zone its timer outlives every pump and fails teardown.
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      settle: false,
    );
    // Live validation is debounced 500 ms.
    await tester.pump(const Duration(milliseconds: 800));

    final issues = handle.container.read(liveValidationProvider).issues;
    expect(issues, isNotEmpty, reason: 'no issues to surface');
    final nodeIssue = issues.firstWhere((i) => i.affectedNodeId != null);

    // The count chips ARE the affordance: tapping either opens the list.
    await tester.tap(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is SkotiqChip &&
                (widget.tone == ChipTone.error ||
                    widget.tone == ChipTone.warning),
            description: 'a validation count chip',
          )
          .first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SequenceIssuesDialog), findsOneWidget);
    for (final issue in issues) {
      expect(
        find.text(issue.title),
        findsOneWidget,
        reason: '"${issue.title}" is counted in the badge but not listed',
      );
    }

    // An issue that names a node jumps to it.
    await tester.tap(find.text(nodeIssue.title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SequenceIssuesDialog), findsNothing);
    expect(
      handle.container.read(selectedNodeIdProvider),
      nodeIssue.affectedNodeId,
    );
  });
}
