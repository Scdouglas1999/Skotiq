// On a phone, a live run's pause, stop and skip ride in the plan row. They
// used to take a row of their own, repeating the frame count, time and state
// the progress card shows, and with the status strip under it a 360 dp phone
// kept little of the plan in view.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mobile_playback_bar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../golden/surface_golden_harness.dart';
import '../../harness/pump_app_screen.dart';

Sequence _plan() {
  final root = InstructionSetNode(name: 'Root');
  final steps = [
    for (final (name, secs) in [
      ('Lum', 120.0),
      ('Red', 120.0),
      ('Green', 120.0),
      ('Blue', 120.0),
    ])
      ExposureNode(name: name, durationSecs: secs, count: 20),
  ];
  return Sequence.create(
    name: 'NGC1313 Plan',
    nodes: {
      for (final s in steps) s.id: s.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [for (final s in steps) s.id]),
    },
    rootNodeId: root.id,
  );
}

void main() {
  testWidgets('a live run puts its controls in the plan row', (tester) async {
    await SurfaceGoldenHarness.ensureCaptureFonts();
    final notifier = CurrentSequenceNotifier();
    // ignore: invalid_use_of_protected_member
    notifier.state = _plan();
    await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(360, 780),
      settle: false,
      extraOverrides: [
        currentSequenceProvider.overrideWith((_) => notifier),
        runRecordProvider.overrideWith(
          (ref) => RunRecordNotifier(
            ref,
            RunRecord(lifecycle: SequenceExecutionState.running),
          ),
        ),
        ledgerClockProvider.overrideWith(
          (ref) => const Stream<DateTime>.empty(),
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 600));

    final bar = find.byType(SequenceToolbar);
    expect(
      find.descendant(of: bar, matching: find.byType(MobilePlaybackBar)),
      findsOneWidget,
    );
    expect(find.byType(MobilePlaybackBar), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Skip'), findsOneWidget);
    // The add button was an unlabeled control to a screen reader.
    expect(find.byTooltip('Add a step'), findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.byTooltip('Undo')),
      findsNothing,
      reason: 'undo leads the menu while the run controls are on the bar',
    );

    final out = Platform.environment['SKOTIQ_PHONE_SHOT'];
    if (out != null) {
      await expectLater(
        find.byType(SequencerScreen),
        matchesGoldenFile(Uri.file(out).toString()),
      );
    }
  });
}
