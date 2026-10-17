// Framing -> Utilities -> Add to Sequence closed its dialog with no toast, no
// error and no navigation while the Sequencer still showed "New Sequence /
// 0 targets" and the editor held no sequence at all. Both halves of that are
// pinned here:
//
//   * the flow may not report success it has not verified — it reads the
//     insert back out of `currentSequenceProvider` before returning true, and
//     tells the user when nothing landed;
//   * the picker is a commit surface with its own Cancel, so a stray click on
//     the barrier can no longer discard a confirmed choice in silence (a
//     barrier dismissal and a real cancel both return null, and null is the
//     one outcome the caller says nothing about).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/add_target_to_sequence_flow.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _target = FramingTarget(
  name: 'M92',
  catalogId: 'M92',
  raHours: 17.285,
  decDegrees: 43.136,
);

/// An editor that accepts the insert and drops the write — the shape of the
/// field failure, where every call returned normally but the Sequencer showed
/// no target afterwards.
///
/// The drop is modelled at the `state` setter rather than by overriding
/// `addTargetHeader`, because that method is an *extension* on
/// [CurrentSequenceNotifier] (`sequence_editor/tree_editing.dart`) and is
/// therefore statically dispatched — a subclass override of it is never
/// called.
class _DroppingSequenceNotifier extends CurrentSequenceNotifier {
  _DroppingSequenceNotifier({required super.ref});

  @override
  set state(Sequence? value) {
    if (value != null &&
        value.nodes.values.whereType<TargetHeaderNode>().isNotEmpty) {
      // Swallow exactly the write that carries the new target.
      return;
    }
    super.state = value;
  }
}

Future<(BuildContext, WidgetRef)> _pumpHost(
  WidgetTester tester,
  ProviderContainer container,
) async {
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
  return (capturedContext, capturedRef);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an insert that does not land is reported, not called a success',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        savedSequencesProvider.overrideWith((ref) async => const <Sequence>[]),
        currentSequenceProvider.overrideWith(
          (ref) => _DroppingSequenceNotifier(ref: ref),
        ),
      ],
    );
    addTearDown(container.dispose);

    final (context, ref) = await _pumpHost(tester, container);

    final future = addFramedTargetToExistingSequence(
      context: context,
      ref: ref,
      target: _target,
    );
    await tester.pumpAndSettle();

    expect(find.text('Add target to sequence'), findsOneWidget);
    await tester.tap(find.text('Add target'));
    await tester.pumpAndSettle();

    expect(
      container
          .read(currentSequenceProvider)
          ?.nodes
          .values
          .whereType<TargetHeaderNode>(),
      isEmpty,
      reason: 'the editor dropped the write, as it did in the field',
    );
    expect(await future, isFalse,
        reason: 'nothing reached the editor, so this is not a success');
    expect(
      find.textContaining('Could not add M92 to the sequence'),
      findsOneWidget,
      reason: 'the user has to be told; a silent close is how this shipped',
    );
  });

  testWidgets('a confirmed insert that lands still reports success',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        savedSequencesProvider.overrideWith((ref) async => const <Sequence>[]),
      ],
    );
    addTearDown(container.dispose);

    final (context, ref) = await _pumpHost(tester, container);

    final future = addFramedTargetToExistingSequence(
      context: context,
      ref: ref,
      target: _target,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add target'));
    await tester.pumpAndSettle();

    expect(await future, isTrue);
    final sequence = container.read(currentSequenceProvider)!;
    expect(sequence.name, 'M92');
    expect(
      sequence.nodes.values.whereType<TargetHeaderNode>().single.targetName,
      'M92',
    );
    expect(find.textContaining('Could not add'), findsNothing);
  });

  testWidgets('a click on the barrier cannot discard the choice in silence',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        savedSequencesProvider.overrideWith((ref) async => const <Sequence>[]),
      ],
    );
    addTearDown(container.dispose);

    final (context, ref) = await _pumpHost(tester, container);

    final future = addFramedTargetToExistingSequence(
      context: context,
      ref: ref,
      target: _target,
    );
    await tester.pumpAndSettle();
    expect(find.text('Add target to sequence'), findsOneWidget);

    // Top-left corner: outside the centred dialog, on the modal barrier.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.text('Add target to sequence'), findsOneWidget,
        reason: 'the picker must survive a stray click');

    // Cancel is still the explicit way out, and it still adds nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await future, isFalse);
    expect(container.read(currentSequenceProvider), isNull);
  });
}
