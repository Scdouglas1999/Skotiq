// At 1280 x 800 the builder gave 300 px to an inspector that said only
// "Select a node" while the plan beside it read "Luminance Lo…", "HFR Autofo…"
// and "13h…". An empty inspector folds to its rail wherever it would cut the
// step names, and opens when a step is selected.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

final _exposure = ExposureNode(
  name: 'Luminance Frames',
  durationSecs: 120,
  count: 40,
);

List<Override> _overrides() {
  final root = InstructionSetNode(name: 'Root');
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = Sequence.create(
    name: 'Laptop builder',
    rootNodeId: root.id,
    nodes: {
      _exposure.id: _exposure.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [_exposure.id]),
    },
  );
  return [
    currentSequenceProvider.overrideWith((_) => notifier),
    ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
  ];
}

Finder _showProperties() => find.byWidgetPredicate(
      (widget) =>
          widget is SkotiqIconButton && widget.tooltip == 'Show Properties',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<HarnessHandle> pumpAt(WidgetTester tester, Size size) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: size,
      extraOverrides: _overrides(),
    );
    await tester.pumpAndSettle();
    return handle;
  }

  // The builder region of a 1280 px window once the navigation rail is out.
  const laptop = Size(1216, 800);

  testWidgets('an empty inspector gives its width to the plan on a laptop',
      (tester) async {
    final handle = await pumpAt(tester, laptop);
    expect(_showProperties(), findsOneWidget);
    expect(find.text('Select a node'), findsNothing);

    handle.container.read(selectedNodeIdProvider.notifier).state = _exposure.id;
    await tester.pumpAndSettle();
    expect(_showProperties(), findsNothing);

    // A selection left over from another plan selects nothing here.
    handle.container.read(selectedNodeIdProvider.notifier).state = 'gone';
    await tester.pumpAndSettle();
    expect(_showProperties(), findsOneWidget);
  });

  testWidgets('a wide window keeps the inspector open', (tester) async {
    await pumpAt(tester, const Size(1856, 1000));
    expect(_showProperties(), findsNothing);
  });
}
