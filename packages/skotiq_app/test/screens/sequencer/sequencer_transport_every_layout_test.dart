// Every layout of the Sequencer shows the run's controls exactly once: a
// phone on its side used to show none (the header hid them for a phone and
// the toolbar drew them only in its narrow row).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
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
  WidgetTester tester,
  Size size,
  SequenceExecutionState state,
) async {
  final notifier = CurrentSequenceNotifier();
  // ignore: invalid_use_of_protected_member
  notifier.state = _plan();
  await pumpAppScreen(
    tester,
    const SequencerScreen(),
    size: size,
    settle: false,
    extraOverrides: [
      currentSequenceProvider.overrideWith((_) => notifier),
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: state)),
      ),
      ledgerClockProvider.overrideWith(
        (ref) => const Stream<DateTime>.empty(),
      ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  const layouts = <(String, Size, DeviceTraits)>[
    ('phone portrait', Size(390, 844), DeviceTraits.phone),
    ('phone landscape', Size(844, 390), DeviceTraits.phone),
    ('tablet landscape', Size(1024, 768), DeviceTraits.phone),
    ('desktop', Size(1440, 900), DeviceTraits.desktop),
  ];

  for (final (name, size, traits) in layouts) {
    // Idle, the transport is Start (or, on the header, the preflight's "Fix
    // N errors" that leads to it).
    testWidgets('$name: idle shows the start control once', (tester) async {
      DeviceTraits.debugOverride = traits;
      addTearDown(() => DeviceTraits.debugOverride = null);
      await _pump(tester, size, SequenceExecutionState.idle);

      expect(find.byKey(TourTarget.sequencerTransport.key), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name: a running plan shows Pause and Stop', (tester) async {
      DeviceTraits.debugOverride = traits;
      addTearDown(() => DeviceTraits.debugOverride = null);
      await _pump(tester, size, SequenceExecutionState.running);

      expect(find.byKey(TourTarget.sequencerTransport.key), findsOneWidget);
      final pause = find.byTooltip('Pause').evaluate().length +
          find.text('Pause').evaluate().length;
      final stop = find.byTooltip('Stop').evaluate().length +
          find.text('Stop').evaluate().length;
      expect(pause, greaterThan(0), reason: 'no Pause at $size');
      expect(stop, greaterThan(0), reason: 'no Stop at $size');
      expect(tester.takeException(), isNull);
    });
  }
}
