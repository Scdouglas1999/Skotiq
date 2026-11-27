// The Sequencer header's Preflight button (and its issue count) opens the
// pre-flight checks to look at. Looking never starts a run, so the dialog it
// opens has no Start: a Start there unparked a parked mount and then started
// nothing. Starting goes through the header's Start.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

Sequence _plan() {
  final root = InstructionSetNode(name: 'Root');
  final step = ExposureNode(name: 'Lum', durationSecs: 120, count: 20);
  return Sequence.create(
    name: 'Plan',
    nodes: {
      step.id: step.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [step.id]),
    },
    rootNodeId: root.id,
  );
}

Iterable<String> _startLabels() => find
    .descendant(
      of: find.byType(PreFlightValidationDialog),
      matching: find.byType(SkotiqButton),
    )
    .evaluate()
    .map((e) => (e.widget as SkotiqButton).label)
    .where((label) => label.startsWith('Start'));

void main() {
  testWidgets("the header's Preflight opens the checks with no Start",
      (tester) async {
    DeviceTraits.debugOverride = DeviceTraits.desktop;
    addTearDown(() => DeviceTraits.debugOverride = null);
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _plan();
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1440, 900),
      settle: false,
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        ledgerClockProvider.overrideWith(
          (ref) => const Stream<DateTime>.empty(),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.widgetWithText(SkotiqButton, 'Preflight'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(PreFlightValidationDialog), findsOneWidget);
    expect(_startLabels(), isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
