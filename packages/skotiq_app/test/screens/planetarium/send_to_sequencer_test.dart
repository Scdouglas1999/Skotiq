// Planetarium send-to-sequencer integration test.
//
// Pins that the existing `addTargetHeaderWithPrompt` helper (the
// shared entrypoint planetarium's "Add to sequence" actions all
// funnel through) correctly populates a TargetHeaderNode in the
// active sequence when one is open, and prompts to create one when
// no sequence is open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/add_target_header_helper.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('appends TargetHeaderNode when a sequence is open',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    container
        .read(currentSequenceProvider.notifier)
        .createSequence(name: 'existing');

    late WidgetRef capturedRef;
    late BuildContext capturedContext;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (ctx, ref, _) {
              capturedRef = ref;
              capturedContext = ctx;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      ),
    );

    final ok = await addTargetHeaderWithPrompt(
      context: capturedContext,
      ref: capturedRef,
      targetNode: TargetHeaderNode(
        name: 'M51',
        targetName: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
      ),
    );
    await tester.pump();

    expect(ok, isTrue);
    final seq = container.read(currentSequenceProvider);
    final targets = seq!.nodes.values.whereType<TargetHeaderNode>().toList();
    expect(targets, hasLength(1));
    expect(targets.first.targetName, 'M51');
    expect(targets.first.raHours, closeTo(13.5, 1e-6));
    expect(targets.first.decDegrees, closeTo(47.2, 1e-6));
  });

  testWidgets('prompts when no sequence is open, then creates and adds',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    // Note: no createSequence() — verifies the prompt branch.
    expect(container.read(currentSequenceProvider), isNull);

    late WidgetRef capturedRef;
    late BuildContext capturedContext;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (ctx, ref, _) {
              capturedRef = ref;
              capturedContext = ctx;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      ),
    );

    // Kick off the helper; it should pop a dialog asking the user
    // whether to create a sequence pre-named after the target.
    final future = addTargetHeaderWithPrompt(
      context: capturedContext,
      ref: capturedRef,
      targetNode: TargetHeaderNode(
        name: 'NGC 891',
        targetName: 'NGC 891',
        raHours: 2.37,
        decDegrees: 42.35,
      ),
    );
    await tester.pump();
    // Confirm the prompt is open and tap "Create & add".
    expect(find.text('No sequence open'), findsOneWidget);
    await tester.tap(find.text('Create & add'));
    await tester.pumpAndSettle();

    final ok = await future;
    expect(ok, isTrue);

    final seq = container.read(currentSequenceProvider);
    expect(seq, isNotNull);
    final targets = seq!.nodes.values.whereType<TargetHeaderNode>().toList();
    expect(targets, hasLength(1));
    expect(targets.first.targetName, 'NGC 891');
  });
}
