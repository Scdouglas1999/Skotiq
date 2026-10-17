// Coverage for the Framing "Add target to an existing sequence" flow — the
// bare-header insert that complements the auto-build path.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/add_target_to_sequence_flow.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

FramingTarget _target() => const FramingTarget(
      name: 'M51',
      catalogId: 'M51',
      raHours: 13.5,
      decDegrees: 47.2,
    );

void main() {
  group('bareTargetHeaderForFramedTarget', () {
    test('carries name/RA/Dec and no child instructions', () {
      final header = bareTargetHeaderForFramedTarget(target: _target());
      expect(header.targetName, 'M51');
      expect(header.raHours, closeTo(13.5, 1e-9));
      expect(header.decDegrees, closeTo(47.2, 1e-9));
      expect(header.childIds, isEmpty);
      expect(header.rotation, isNull);
    });

    test('preserves a non-zero framing rotation', () {
      final header = bareTargetHeaderForFramedTarget(
          target: _target(), rotationDegrees: 37.5);
      expect(header.rotation, closeTo(37.5, 1e-9));
    });

    test('drops a zero rotation (no constraint)', () {
      final header = bareTargetHeaderForFramedTarget(
          target: _target(), rotationDegrees: 0);
      expect(header.rotation, isNull);
    });
  });

  group('addFramedTargetToExistingSequence', () {
    testWidgets('appends a bare header to the open sequence (default pick)',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          // Keep the picker hermetic: no library round-trip.
          savedSequencesProvider
              .overrideWith((ref) async => const <Sequence>[]),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'manual');

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

      final future = addFramedTargetToExistingSequence(
        context: capturedContext,
        ref: capturedRef,
        target: _target(),
        rotationDegrees: 12,
      );
      await tester.pumpAndSettle();

      // Picker dialog is open; the open sequence is the default — just confirm.
      expect(find.text('Add target to sequence'), findsOneWidget);
      await tester.tap(find.text('Add target'));
      await tester.pumpAndSettle();

      final ok = await future;
      expect(ok, isTrue);

      final seq = container.read(currentSequenceProvider)!;
      final targets = seq.nodes.values.whereType<TargetHeaderNode>().toList();
      expect(targets, hasLength(1));
      expect(targets.first.targetName, 'M51');
      expect(targets.first.rotation, closeTo(12, 1e-9));
      // Bare insert — the target group has no generated instruction children.
      expect(targets.first.childIds, isEmpty);
    });

    testWidgets('creates a new empty sequence when none is open',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          savedSequencesProvider
              .overrideWith((ref) async => const <Sequence>[]),
        ],
      );
      addTearDown(container.dispose);

      // No createSequence — exercises the empty-sequence fallback.
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

      final future = addFramedTargetToExistingSequence(
        context: capturedContext,
        ref: capturedRef,
        target: _target(),
      );
      await tester.pumpAndSettle();

      // Only "New empty sequence" exists; it is pre-selected.
      expect(find.text('New empty sequence'), findsOneWidget);
      await tester.tap(find.text('Add target'));
      await tester.pumpAndSettle();

      final ok = await future;
      expect(ok, isTrue);

      final seq = container.read(currentSequenceProvider);
      expect(seq, isNotNull);
      final targets = seq!.nodes.values.whereType<TargetHeaderNode>().toList();
      expect(targets, hasLength(1));
      expect(targets.first.targetName, 'M51');
    });

    testWidgets('cancelling the picker adds nothing', (tester) async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          savedSequencesProvider
              .overrideWith((ref) async => const <Sequence>[]),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'manual');

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

      final future = addFramedTargetToExistingSequence(
        context: capturedContext,
        ref: capturedRef,
        target: _target(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final ok = await future;
      expect(ok, isFalse);
      final seq = container.read(currentSequenceProvider)!;
      expect(seq.nodes.values.whereType<TargetHeaderNode>(), isEmpty);
    });

    testWidgets(
        'library failure blocks false-empty destinations and retries the fetch',
        (tester) async {
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          savedSequencesProvider.overrideWith((ref) async {
            attempts++;
            if (attempts == 1) {
              throw StateError('sequence host unavailable');
            }
            return const <Sequence>[];
          }),
        ],
      );
      addTearDown(container.dispose);

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

      final future = addFramedTargetToExistingSequence(
        context: capturedContext,
        ref: capturedRef,
        target: _target(),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load saved sequences'), findsOneWidget);
      expect(
        find.textContaining('Bad state: sequence host unavailable'),
        findsOneWidget,
      );
      expect(find.text('New empty sequence'), findsNothing);
      expect(attempts, 1);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(find.text('Add target to sequence'), findsOneWidget);
      expect(find.text('New empty sequence'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await future, isFalse);
      expect(container.read(currentSequenceProvider), isNull);
    });
  });
}
