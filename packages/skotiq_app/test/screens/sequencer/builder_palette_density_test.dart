// The Builder's node palette is a list to scan, so it has to show a useful
// number of nodes at once. Each row used to carry a two-line description at
// 8px vertical padding, about 70px a row, and a 1080p screen showed seven of
// them. One line, with the full sentence on hover, roughly doubles that.
//
// The canvas header (Step, Filter / exp, Count, Duration, ETA) names the
// columns of the step rows, so an empty sequence does not show it over its
// lone "Drop a node here" line.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

({CurrentSequenceNotifier notifier, List<Override> overrides}) _empty() {
  final notifier = CurrentSequenceNotifier();
  final root = InstructionSetNode(name: 'Root');
  // ignore: invalid_use_of_protected_member
  notifier.state = Sequence.create(
    name: 'New Sequence',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
  return (
    notifier: notifier,
    overrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      sequenceExecutionStateProvider
          .overrideWith((ref) => SequenceExecutionState.idle),
      // The ETA column's wall clock would leave a periodic timer behind.
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ],
  );
}

Future<HarnessHandle> _pumpBuilder(
  WidgetTester tester,
  List<Override> overrides,
) async {
  final handle = await pumpAppScreen(
    tester,
    const SequencerScreen(),
    // The imaging laptop: 1920x1080 less the navigation rail and title bar,
    // on a pointer platform where buttons keep their compact desktop height.
    size: const Size(1660, 940),
    theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.windows),
    extraOverrides: overrides,
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 400));
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('palette rows hold one description line with the rest on hover',
      (tester) async {
    final seeded = _empty();
    final handle = await _pumpBuilder(tester, seeded.overrides);

    final imaging = handle.container
        .read(nodePaletteProvider)
        .firstWhere((category) => category.name.toUpperCase() == 'IMAGING');
    final first = imaging.items[0];
    final second = imaging.items[1];

    final description = find.text(first.description);
    expect(description, findsOneWidget);
    expect(tester.widget<Text>(description).maxLines, 1);
    final tooltip = tester.widget<SkotiqTooltip>(
      find.ancestor(of: description, matching: find.byType(SkotiqTooltip)),
    );
    expect(tooltip.message, first.description,
        reason: 'the sentence the ellipsis cut is one hover away');

    // Row pitch: from one node's description to the next one's.
    final pitch = tester.getTopLeft(find.text(second.description)).dy -
        tester.getTopLeft(description).dy;
    expect(pitch, lessThanOrEqualTo(56));

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the step table header waits for the first step', (tester) async {
    final seeded = _empty();
    await _pumpBuilder(tester, seeded.overrides);

    expect(find.text('Filter / exp'), findsNothing);
    expect(find.textContaining('Drop a node here'), findsOneWidget);

    final root = seeded.notifier.state!.rootNode!;
    seeded.notifier.addNode(
      ExposureNode(name: 'Take exposures'),
      parentId: root.id,
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Filter / exp'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });
}
