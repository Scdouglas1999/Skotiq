// The phone's Start (on the builder's toolbar while no run is live) runs
// through the pre-flight dialog, which closes before it starts the run. The
// result was reported on the dialog's own context, gone by then, so a refused
// start said nothing on a phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/sequence_action_service.dart';
import 'package:skotiq_app/tours/tour_target.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _RefusingStart extends SequenceActionService {
  _RefusingStart(super.ref);

  @override
  Future<CommandActionResult> start() async =>
      const CommandActionResult.failure('The camera is not connected');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a refused start is reported after the dialog closes',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SequenceToolbar(colors: SkotiqColors.dark, showStart: true),
        ),
      ),
      size: const Size(390, 844),
      extraOverrides: [
        sequenceActionServiceProvider.overrideWith(_RefusingStart.new),
      ],
    );
    final exposure = ExposureNode(name: 'Lights', durationSecs: 60, count: 5);
    handle.container.read(currentSequenceProvider.notifier).loadSequence(
          Sequence.create(
            name: 'Phone start',
            rootNodeId: exposure.id,
            nodes: {exposure.id: exposure},
          ),
          discardUnsaved: true,
        );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(TourTarget.sequencerTransport.key));
    await tester.pump(const Duration(milliseconds: 500));
    final dialog = find.byType(PreFlightValidationDialog);
    expect(dialog, findsOneWidget);
    final onStart =
        tester.widget<PreFlightValidationDialog>(dialog).onStartSequence!;
    // As the dialog's Start does: close, then start.
    Navigator.of(tester.element(dialog)).pop();
    onStart();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('The camera is not connected'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
