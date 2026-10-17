// Wave-3 P3 regressions for the Sequencer builder surfaces.
//
// Each group pins one thing the app used to get visibly wrong:
//   * the node palette ranked a DESCRIPTION hit above an exact NAME hit, so
//     the first row after typing "Dither" was Smart Exposure;
//   * the snippet card's "+" was a decorative Icon, so the only ways in were
//     a drag or an undocumented double-click;
//   * the header node chip counted the invisible root container, reading
//     "1 node" beside a tree body reading "0 steps";
//   * thirteen glyph-only toolbar actions exposed no accessible name at all.
//
// The palette / toolbar / header assertions drive the REAL SequencerScreen so
// the production call site is under test, not just the helper behind it.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequence_counts.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/tabs/templates_tab.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette_search.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/quick_start_wizard_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/snippet_palette.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';
import 'canvas_bar_menu.dart';

/// A rooted sequence with nothing in it — what "New Sequence" produces.
Sequence _emptySequence() {
  final root = InstructionSetNode(name: 'Sequence');
  return Sequence.create(
    name: 'Untitled',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
}

/// Root + one container + one exposure = 2 real instructions.
Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final container = InstructionSetNode(name: 'Lights');
  final root = InstructionSetNode(name: 'Root');
  final nodes = <String, SequenceNode>{
    exposure.id: exposure.copyWith(parentId: container.id),
    container.id:
        container.copyWith(parentId: root.id, childIds: [exposure.id]),
    root.id: root.copyWith(childIds: [container.id]),
  };
  return Sequence.create(name: 'Test', nodes: nodes, rootNodeId: root.id);
}

Future<HarnessHandle> _pumpBuilder(WidgetTester tester) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _seedSequence();

  final handle = await pumpAppScreen(
    tester,
    const SequencerScreen(),
    size: const Size(1800, 1000),
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The ledger ETA clock is a real periodic stream; in the fake-async
      // zone its timer outlives every pump and fails teardown.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 600));
  return handle;
}

/// The NODE-PALETTE rows currently on screen, top to bottom.
///
/// Scoped to the palette column (the one owning the "Search nodes…" field)
/// — the same words appear in the snippet palette and the tree, and a global
/// `find.text` picks those up and scrambles the order under test.
List<String> _paletteRowOrder(WidgetTester tester, List<String> candidates) {
  // The result LIST only. Scoping to the whole palette column would also
  // match the query the test just typed into the search field, which sits
  // above every row and would always look like the top hit.
  //
  // The search field is a SkotiqTextField now, and it has Columns of its
  // own between the hint and the palette's, so "the first Column ancestor" is
  // no longer the palette. Walk out until a Column is found that actually
  // holds the result list.
  Finder? list;
  final columns = find.ancestor(
    of: find.text('Search nodes…'),
    matching: find.byType(Column),
  );
  for (final element in columns.evaluate()) {
    final candidate = find.descendant(
      of: find.byElementPredicate((e) => identical(e, element)),
      matching: find.byType(ListView),
    );
    if (candidate.evaluate().isNotEmpty) {
      list = candidate;
      break;
    }
  }
  expect(list, isNotNull, reason: 'the palette result list must be on screen');
  final seen = <(double, String)>[];
  for (final name in candidates) {
    final rows = find.descendant(of: list!.first, matching: find.text(name));
    for (final element in rows.evaluate()) {
      final box = element.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      seen.add((box.localToGlobal(Offset.zero).dy, name));
    }
  }
  seen.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final s in seen) s.$2];
}

Future<void> _searchPalette(WidgetTester tester, String query) async {
  final search = find.ancestor(
    of: find.text('Search nodes…'),
    matching: find.byType(TextField),
  );
  expect(search, findsOneWidget, reason: 'palette search field must exist');
  await tester.enterText(search, query);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('node palette search ranking', () {
    // The three searches from the sweep, asserted against the REAL palette
    // as rendered inside SequencerScreen.
    const cases = <(String, String, String)>[
      ('Dither', 'Dither', 'Smart exposure'),
      ('loop', 'Loop', 'Instruction set'),
      ('start guiding', 'Start guiding', 'Photometry run (template)'),
    ];

    for (final (query, wanted, decoy) in cases) {
      testWidgets('"$query" puts $wanted above $decoy', (tester) async {
        await _pumpBuilder(tester);
        await _searchPalette(tester, query);

        final order = _paletteRowOrder(tester, [wanted, decoy]);
        expect(order, isNotEmpty,
            reason: 'neither "$wanted" nor "$decoy" rendered for "$query"');
        expect(
          order.first,
          wanted,
          reason: 'typing "$query" must list "$wanted" first, got $order',
        );
      });
    }

    test('an exact name match outranks a description-only match', () {
      final categories = [
        NodePaletteCategory(
          name: 'Imaging',
          icon: 'camera',
          items: [
            NodePaletteItem(
              name: 'Smart Exposure',
              icon: 'camera',
              description: 'handles rotation + dither',
              createNode: () => DelayNode(seconds: 1),
            ),
            NodePaletteItem(
              name: 'Dither',
              icon: 'move',
              description: 'Move the mount slightly',
              createNode: () => DelayNode(seconds: 1),
            ),
          ],
        ),
      ];

      final ranked = rankNodePaletteMatches(categories, 'Dither');
      expect(ranked.single.items.first.name, 'Dither');
    });

    test('a later category holding the exact match is hoisted first', () {
      final categories = [
        NodePaletteCategory(
          name: 'Science',
          icon: 'flask',
          items: [
            NodePaletteItem(
              name: 'Photometry Run',
              icon: 'flask',
              description: 'Center, start guiding, then run photometry',
              createNode: () => DelayNode(seconds: 1),
            ),
          ],
        ),
        NodePaletteCategory(
          name: 'Guiding',
          icon: 'crosshair',
          items: [
            NodePaletteItem(
              name: 'Start Guiding',
              icon: 'crosshair',
              description: 'Begin autoguiding',
              createNode: () => DelayNode(seconds: 1),
            ),
          ],
        ),
      ];

      final ranked = rankNodePaletteMatches(categories, 'start guiding');
      expect(ranked.first.name, 'Guiding');
      expect(ranked.first.items.single.name, 'Start Guiding');
    });

    test('an empty query is passed through untouched', () {
      final categories = [
        NodePaletteCategory(name: 'Logic', icon: 'git', items: [
          NodePaletteItem(
            name: 'Loop',
            icon: 'repeat',
            description: 'Repeat',
            createNode: () => DelayNode(seconds: 1),
          ),
        ]),
      ];
      expect(rankNodePaletteMatches(categories, '   '), same(categories));
    });
  });

  group('snippet palette insert affordance', () {
    testWidgets('the card\'s + inserts on a single tap', (tester) async {
      final inserted = <TemplateSnippet>[];

      await pumpAppScreen(
        tester,
        Builder(
          builder: (context) => SizedBox(
            width: 420,
            height: 900,
            child: SnippetPalette(
              colors: SkotiqColors.of(context),
              onSnippetTap: inserted.add,
            ),
          ),
        ),
        size: const Size(1200, 1000),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 300));

      final plus = find.byTooltip('Insert into sequence');
      expect(
        plus,
        findsWidgets,
        reason: 'every snippet card needs a real insert button, not a '
            'decorative glyph that only paints on hover',
      );

      await tester.tap(plus.first, warnIfMissed: false);
      await tester.pump();

      expect(inserted, hasLength(1));
    });

    testWidgets('the footer no longer promises a plain tap', (tester) async {
      await pumpAppScreen(
        tester,
        Builder(
          builder: (context) => SizedBox(
            width: 420,
            height: 900,
            child: SnippetPalette(colors: SkotiqColors.of(context)),
          ),
        ),
        size: const Size(1200, 1000),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('Drag templates to the sequence tree or tap to insert'),
        findsNothing,
      );
    });
  });

  group('node counts exclude the implicit root', () {
    test('an empty rooted sequence counts zero instructions', () {
      final root = InstructionSetNode(name: 'Sequence');
      final sequence = Sequence.create(
        name: 'New',
        nodes: {root.id: root},
        rootNodeId: root.id,
      );
      expect(visibleInstructionCount(sequence), 0);
    });

    test('an unrooted sequence keeps the raw map size', () {
      final delay = DelayNode(seconds: 5);
      final sequence = Sequence.create(name: 'Flat', nodes: {delay.id: delay});
      expect(visibleInstructionCount(sequence), 1);
    });

    testWidgets('the header chip matches the tree, not the map',
        (tester) async {
      await _pumpBuilder(tester);
      // Root + container + exposure = 3 map entries, 2 real instructions.
      // The count is one clause of the canvas bar's summary chip
      // ("1 target · 2 nodes · ~12m"), not a chip of its own.
      expect(find.textContaining('2 nodes'), findsOneWidget);
      expect(find.text('3 nodes'), findsNothing);
    });
  });

  group('Save as Template on an empty sequence', () {
    Future<void> openDialog(WidgetTester tester) async {
      final notifier = CurrentSequenceNotifier();
      // ignore: invalid_use_of_protected_member
      notifier.state = _emptySequence();

      await pumpAppScreen(
        tester,
        const TemplatesTab(),
        size: const Size(1400, 900),
        settle: false,
        extraOverrides: [
          currentSequenceProvider.overrideWith((_) => notifier),
          sequenceExecutionStateProvider
              .overrideWith((ref) => SequenceExecutionState.idle),
          // The ledger ETA clock is a real periodic stream; in the
          // fake-async zone its timer outlives every pump and fails
          // teardown.
          ledgerClockProvider
              .overrideWith((ref) => const Stream<DateTime>.empty()),
        ],
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Save as template'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    }

    testWidgets('says zero instructions instead of "1 nodes"', (tester) async {
      await openDialog(tester);

      expect(find.textContaining('1 nodes'), findsNothing);
      expect(
        find.textContaining('no instructions yet'),
        findsOneWidget,
        reason: 'the info line must describe the empty sequence, not count '
            'the invisible root container',
      );
    });

    testWidgets('refuses to save an empty template', (tester) async {
      await openDialog(tester);

      final button = tester.widget<SkotiqButton>(
        find.widgetWithText(SkotiqButton, 'Save Template'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('Quick-Start wizard target search', () {
    Future<HarnessHandle> openWizard(WidgetTester tester) async {
      final handle = await pumpAppScreen(
        tester,
        const QuickStartWizardDialog(),
        size: const Size(1200, 1000),
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 400));
      return handle;
    }

    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Target Name'),
        query,
      );
      // Past the 300 ms debounce, then a frame for the async result.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an empty library says so instead of showing nothing',
        (tester) async {
      await openWizard(tester);
      await search(tester, 'M31');

      expect(
        find.textContaining('Your target library is empty'),
        findsOneWidget,
        reason: 'a finished search that found nothing must say why',
      );
    });

    testWidgets('a populated library reports no match for the typed name',
        (tester) async {
      final handle = await openWizard(tester);
      await handle.database.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'M42', ra: 5.59, dec: -5.39),
      );
      await tester.pump();

      await search(tester, 'zzqq');

      expect(find.textContaining('No saved target matches "zzqq"'),
          findsOneWidget);
      expect(find.textContaining('Your target library is empty'), findsNothing);
    });

    testWidgets('a hit still renders the results list, not a message',
        (tester) async {
      final handle = await openWizard(tester);
      await handle.database.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'M42', ra: 5.59, dec: -5.39),
      );
      await tester.pump();

      await search(tester, 'M42');

      expect(find.textContaining('No saved target matches'), findsNothing);
      expect(find.textContaining('Your target library is empty'), findsNothing);
      expect(find.text('M42'), findsWidgets);
    });
  });

  group('toolbar accessibility', () {
    testWidgets('every glyph-only action exposes its label as a button',
        (tester) async {
      final handle = SemanticsBinding.instance.ensureSemantics();
      await _pumpBuilder(tester);

      // The canvas bar's glyphs. Every one is a SkotiqIconButton, whose
      // required tooltip doubles as its semantics label — which is what
      // stopped the old bar shipping thirteen unnamed tappable boxes.
      for (final label in const [
        'Undo (Ctrl+Z)',
        'Redo (Ctrl+Y)',
        'More actions',
      ]) {
        expect(
          find.bySemanticsLabel(label),
          findsOneWidget,
          reason: '"$label" must be reachable by name, not just by hovering '
              'an unnamed glyph',
        );
      }

      // Named AND actionable: the label and the tap must live on one node,
      // or a screen reader announces a button it cannot press.
      final data = tester
          .getSemantics(find.bySemanticsLabel('More actions'))
          .getSemanticsData();
      expect(data.label, 'More actions');
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);

      // The actions that moved behind that button did not lose their names:
      // in a menu they are WORDS, which is stronger than a tooltip.
      await openCanvasBarMenu(tester);
      for (final label in const [
        'New sequence',
        'Quick-start wizard',
        'Plan mosaic',
        'Plan tonight',
        'Open sequence',
        'Polar alignment',
      ]) {
        expect(
          canvasBarAction(label),
          findsOneWidget,
          reason: '"$label" must still be reachable by name',
        );
      }

      handle.dispose();
    });
  });
}
