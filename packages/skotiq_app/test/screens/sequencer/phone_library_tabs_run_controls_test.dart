// On a phone the run's controls ride in the Builder tab's toolbar. While a run
// is live the Templates and Saved tabs offer them too, so a phone that opened
// the library mid-run can still pause or stop it without going back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/router/sequencer_route.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mobile_playback_bar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/tours/tour_target.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;

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

Future<void> _pump(
    WidgetTester tester, SequenceExecutionState lifecycle) async {
  DeviceTraits.debugOverride = DeviceTraits.phone;
  addTearDown(() => DeviceTraits.debugOverride = null);
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _plan();
  await pumpAppScreen(
    tester,
    const SequencerScreen(),
    size: const Size(390, 844),
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      ledgerClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: lifecycle)),
      ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _open(WidgetTester tester, SequencerTab tab) async {
  // A phone's tab strip shows icons only.
  await tester.tap(find.byIcon(tab.icon).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  for (final tab in [SequencerTab.templates, SequencerTab.sequences]) {
    testWidgets('${tab.label} offers the live run its controls',
        (tester) async {
      await _pump(tester, SequenceExecutionState.running);
      await _open(tester, tab);

      // The Builder tab stays built offstage; this one is the visible bar.
      final bars = find.byType(MobilePlaybackBar);
      expect(bars.hitTestable(), findsOneWidget);
      // The tour's transport key stays on the Builder tab's bar alone.
      expect(
        find
            .byKey(TourTarget.sequencerTransport.key, skipOffstage: false)
            .evaluate()
            .length,
        lessThanOrEqualTo(1),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('${tab.label} has no run controls with no run', (tester) async {
      await _pump(tester, SequenceExecutionState.idle);
      await _open(tester, tab);

      expect(find.byType(MobilePlaybackBar).hitTestable(), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
