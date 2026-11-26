// On a touch screen narrower than a desktop (an unfolded Fold, a tablet held
// upright) the builder's side panels slide over the plan instead of sitting
// beside it. Docked, an open inspector left the plan too narrow for the
// ledger, which fell back to cards; and the inspector had no way to be put
// away once a step had been tapped.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_properties_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/pump_app_screen.dart';

Sequence _seedSequence() {
  final exposure = ExposureNode(name: 'Lum', durationSecs: 120, count: 10);
  final root = InstructionSetNode(name: 'Root');
  return Sequence.create(
    name: 'Fold builder',
    rootNodeId: root.id,
    nodes: {
      exposure.id: exposure.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [exposure.id]),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // An unfolded Fold: about 750 x 830 dp.
  const fold = Size(750, 830);

  testWidgets(
      'a tapped step opens the inspector over the plan; a tap beside '
      'it puts it away', (tester) async {
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _seedSequence();
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: fold,
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        ledgerClockProvider.overrideWith(
          (ref) => const Stream<DateTime>.empty(),
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.byType(NodePropertiesPanel), findsNothing);

    await tester.tap(find.text('Lum').first);
    await tester.pumpAndSettle();
    expect(find.byType(NodePropertiesPanel), findsOneWidget);
    // Over the plan, not beside it: the step is still laid out at the
    // width the closed inspector left it.
    expect(find.text('Lum'), findsWidgets);

    // The left edge of the canvas is clear of the inspector sheet.
    await tester.tapAt(const Offset(120, 600));
    await tester.pumpAndSettle();
    expect(find.byType(NodePropertiesPanel), findsNothing);
    expect(handle.container.read(selectedNodeIdProvider), isNull);
    expect(tester.takeException(), isNull);
  });
}
