// Typing a number into the inline popover is one edit: one undo step, as in
// the inspector's field. The popover used to write the node on every
// keystroke, so typing "300" left three undo steps.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary.dart'
    show InlineEditKind;
import 'package:skotiq_app/screens/sequencer/widgets/node_summary_inline_editors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('typing a number in the popover is one undo step',
      (tester) async {
    final exposure = ExposureNode(
      id: 'exp',
      name: 'Lights',
      parentId: 'root',
      durationSecs: 60,
    );
    final plan = Sequence.create(
      name: 'Plan',
      rootNodeId: 'root',
      nodes: {
        'root': InstructionSetNode(
          id: 'root',
          name: 'Root',
          childIds: const ['exp'],
        ),
        'exp': exposure,
      },
    );
    final anchorKey = GlobalKey();
    late WidgetRef widgetRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [inMemoryDatabaseOverride()],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            widgetRef = ref;
            return Center(child: SizedBox(key: anchorKey, width: 40));
          }),
        ),
      ),
    ));
    final notifier = widgetRef.read(currentSequenceProvider.notifier);
    notifier.loadSequence(plan);
    final before = notifier.undoStack.length;

    unawaited(showInlineNodeEditor(
      context: anchorKey.currentContext!,
      ref: widgetRef,
      node: exposure,
      kind: InlineEditKind.exposureDuration,
      anchor: anchorKey.currentContext!.findRenderObject()! as RenderBox,
    ));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    for (final typed in ['3', '30', '300']) {
      await tester.enterText(field, typed);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 400));

    final edited = widgetRef.read(currentSequenceProvider)!.nodes['exp']!
        as ExposureNode;
    expect(edited.durationSecs, 300);
    expect(notifier.undoStack.length - before, 1);
  });
}
