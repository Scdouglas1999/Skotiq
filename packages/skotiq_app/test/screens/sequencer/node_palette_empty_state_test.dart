// A palette search that matches nothing must SAY so.
//
// Before this, every palette surface built its category list straight from
// `rankNodePaletteMatches` output; when that came back empty the ListView
// rendered zero children and the panel body went blank between the search
// field and the help tip. The operator could not tell a failed search from a
// node that does not exist.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette_empty_state.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// A term no palette item's name or description contains.
const _noMatch = 'zzzqqq';

List<Override> _overrides() {
  final notifier = CurrentSequenceNotifier();
  final root = InstructionSetNode(name: 'Root');
  // ignore: invalid_use_of_protected_member
  notifier.state = Sequence.create(
    name: 'Test',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    sequenceExecutionStateProvider
        .overrideWith((ref) => SequenceExecutionState.idle),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('toolbox Nodes tab explains a search that matches nothing',
      (tester) async {
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1800, 1000),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    final search = find.widgetWithText(TextField, 'Search nodes…');
    expect(search, findsOneWidget);

    await tester.enterText(search, _noMatch);
    await tester.pump();

    expect(find.byType(NodePaletteEmptyState), findsOneWidget);
    expect(find.text('No nodes match "$_noMatch"'), findsOneWidget);

    // The clear affordance has to actually restore the catalogue.
    await tester.tap(find.text('Clear search'));
    await tester.pump();
    expect(find.byType(NodePaletteEmptyState), findsNothing);
    // The palette's group labels are eyebrows now (11 px uppercase, 03 §2).
    expect(find.text('IMAGING'), findsWidgets);

    // Drain the live-validation debounce so the binding does not fail the
    // test on a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('desktop sidebar palette explains an empty result',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => NodePalette(colors: SkotiqColors.of(context)),
      ),
      size: const Size(400, 900),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.widgetWithText(TextField, 'Search nodes…'),
      _noMatch,
    );
    await tester.pump();

    expect(find.byType(NodePaletteEmptyState), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('mobile sheet palette explains an empty result', (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => NodePalette(
          colors: SkotiqColors.of(context),
          isMobileSheet: true,
        ),
      ),
      size: const Size(390, 844),
      extraOverrides: _overrides(),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.widgetWithText(TextField, 'Search nodes…'),
      _noMatch,
    );
    await tester.pump();

    expect(find.byType(NodePaletteEmptyState), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });
}
