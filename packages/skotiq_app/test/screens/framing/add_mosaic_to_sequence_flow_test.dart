// The Framing "Add to Sequence" utility must not silently throw away a drawn
// mosaic.
//
// With Mosaic ON and a 2x2 grid drawn on the canvas, this flow inserted exactly
// ONE bare target header at the grid's CENTRE. The four panels the user composed
// were dropped with no warning: the dialog said only 'Insert "<target>" as a new
// target group', and the resulting sequence contained a single centre frame.
//
// The contract pinned here:
//   * a mosaic of 2+ panels inserts one target group PER PANEL, each at its own
//     coordinates and in the panels' capture order;
//   * each panel header carries its MosaicPanelInfo (so captured frames are
//     stamped with their panel identity, as the wizard-built path does);
//   * the dialog states the panel count instead of promising one target group;
//   * a single panel / no mosaic is unchanged (one header for the framed target).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/add_target_to_sequence_flow.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

FramingTarget _target() => const FramingTarget(
      name: 'M42',
      catalogId: 'M42',
      raHours: 5.588,
      decDegrees: -5.39,
    );

/// A 2x2 grid in capture order, matching what `_recalculateMosaicPanels` emits.
List<FramingMosaicPanel> _grid2x2() => const [
      FramingMosaicPanel(
        index: 0,
        column: 0,
        row: 0,
        centerRaHours: 5.55,
        centerDecDegrees: -5.14,
        name: 'Panel 1 (0,0)',
      ),
      FramingMosaicPanel(
        index: 1,
        column: 1,
        row: 0,
        centerRaHours: 5.62,
        centerDecDegrees: -5.14,
        name: 'Panel 2 (1,0)',
      ),
      FramingMosaicPanel(
        index: 2,
        column: 1,
        row: 1,
        centerRaHours: 5.62,
        centerDecDegrees: -5.64,
        name: 'Panel 3 (1,1)',
      ),
      FramingMosaicPanel(
        index: 3,
        column: 0,
        row: 1,
        centerRaHours: 5.55,
        centerDecDegrees: -5.64,
        name: 'Panel 4 (0,1)',
      ),
    ];

void main() {
  group('bareTargetHeadersForMosaicPanels', () {
    test('one header per panel, each at its own coordinates', () {
      final headers = bareTargetHeadersForMosaicPanels(
        target: _target(),
        panels: _grid2x2(),
      );

      expect(headers, hasLength(4));
      expect(
        headers.map((h) => h.raHours),
        [5.55, 5.62, 5.62, 5.55],
      );
      expect(
        headers.map((h) => h.decDegrees),
        [-5.14, -5.14, -5.64, -5.64],
      );
      // Every header is distinct — the bug collapsed all four onto the centre.
      expect(
        headers.map((h) => '${h.raHours}/${h.decDegrees}').toSet(),
        hasLength(4),
      );
      for (final header in headers) {
        expect(header.childIds, isEmpty, reason: 'bare insert');
      }
    });

    test('headers are named per panel and carry MosaicPanelInfo', () {
      final headers = bareTargetHeadersForMosaicPanels(
        target: _target(),
        panels: _grid2x2(),
      );

      expect(headers.map((h) => h.targetName), [
        'M42 Panel 1',
        'M42 Panel 2',
        'M42 Panel 3',
        'M42 Panel 4',
      ]);
      for (var i = 0; i < headers.length; i++) {
        final info = headers[i].mosaicPanel;
        expect(info, isNotNull, reason: 'panel $i lost its mosaic identity');
        expect(info!.mosaicName, 'M42');
        expect(info.panelIndex, _grid2x2()[i].index);
        expect(info.row, _grid2x2()[i].row);
        expect(info.column, _grid2x2()[i].column);
        expect(info.totalPanels, 4);
      }
    });

    test('framing rotation rides onto every panel', () {
      final headers = bareTargetHeadersForMosaicPanels(
        target: _target(),
        panels: _grid2x2(),
        rotationDegrees: 33.0,
      );
      for (final header in headers) {
        expect(header.rotation, closeTo(33.0, 1e-9));
      }
    });
  });

  group('addFramedTargetToExistingSequence with a mosaic', () {
    Future<
        ({
          ProviderContainer container,
          BuildContext context,
          WidgetRef ref,
        })> host(WidgetTester tester) async {
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
      return (
        container: container,
        context: capturedContext,
        ref: capturedRef,
      );
    }

    testWidgets('a 2x2 mosaic inserts four target groups, not one centre frame',
        (tester) async {
      final h = await host(tester);

      final future = addFramedTargetToExistingSequence(
        context: h.context,
        ref: h.ref,
        target: _target(),
        rotationDegrees: 0,
        mosaicPanels: _grid2x2(),
      );
      await tester.pumpAndSettle();

      // The dialog must say what it will actually do.
      expect(find.text('Add mosaic to sequence'), findsOneWidget);
      expect(
        find.textContaining('4 target groups'),
        findsOneWidget,
        reason: 'the dialog must state the panel count, not promise one group',
      );
      await tester.tap(find.text('Add 4 panels'));
      await tester.pumpAndSettle();

      expect(await future, isTrue);

      final seq = h.container.read(currentSequenceProvider)!;
      final targets = seq.nodes.values.whereType<TargetHeaderNode>().toList()
        ..sort((a, b) => (a.mosaicPanel?.panelIndex ?? 0)
            .compareTo(b.mosaicPanel?.panelIndex ?? 0));

      expect(targets, hasLength(4), reason: 'the mosaic panels were discarded');
      expect(targets.map((t) => t.raHours), [5.55, 5.62, 5.62, 5.55]);
      // No header sits at the grid centre — that was the whole bug.
      const centreRa = 5.588;
      for (final target in targets) {
        expect(
          (target.raHours - centreRa).abs(),
          greaterThan(1e-6),
          reason: 'a panel collapsed onto the mosaic centre',
        );
      }
    });

    testWidgets('a single panel behaves exactly as no mosaic', (tester) async {
      final h = await host(tester);

      final future = addFramedTargetToExistingSequence(
        context: h.context,
        ref: h.ref,
        target: _target(),
        mosaicPanels: [_grid2x2().first],
      );
      await tester.pumpAndSettle();

      // One panel is not a mosaic: the plain copy and plain button.
      expect(find.text('Add target to sequence'), findsOneWidget);
      await tester.tap(find.text('Add target'));
      await tester.pumpAndSettle();

      expect(await future, isTrue);
      final targets = h.container
          .read(currentSequenceProvider)!
          .nodes
          .values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(1));
      expect(targets.first.targetName, 'M42');
      expect(targets.first.raHours, closeTo(5.588, 1e-9));
    });

    testWidgets('cancelling a mosaic insert adds nothing', (tester) async {
      final h = await host(tester);

      final future = addFramedTargetToExistingSequence(
        context: h.context,
        ref: h.ref,
        target: _target(),
        mosaicPanels: _grid2x2(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await future, isFalse);
      expect(
        h.container
            .read(currentSequenceProvider)!
            .nodes
            .values
            .whereType<TargetHeaderNode>(),
        isEmpty,
      );
    });
  });
}
