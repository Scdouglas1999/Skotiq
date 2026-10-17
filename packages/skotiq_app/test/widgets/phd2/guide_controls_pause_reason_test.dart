// An unavailable control has to say why.
//
// Pause is a PHD2 command, and the screen correctly passes no handler for the
// built-in guider. Left unexplained, "no handler" reaches the operator as a
// button that looks ordinary and changes nothing anywhere — not the button, not
// the state chip, not the status bar, not the log — over the one control whose
// entire job is to tell them corrections are suspended.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _reason = 'Pause is a PHD2 feature. The built-in guider has no pause.';

Future<void> _pump(
  WidgetTester tester, {
  required String? reason,
  Future<void> Function()? onPause,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 700,
          child: GuideControlsPanel(
            state: Phd2GuidingState.guiding,
            isConnected: true,
            onStartGuiding: () async {},
            onStopGuiding: () async {},
            onPauseGuiding: onPause,
            pauseUnavailableReason: reason,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an unavailable Pause carries its reason', (tester) async {
    await _pump(tester, reason: _reason);

    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
                of: find.text('Pause'), matching: find.byType(Tooltip)),
          )
          .message,
      _reason,
    );

    // The reason has to reach assistive tech too, not only a hover.
    expect(find.bySemanticsLabel('Pause — $_reason'), findsOneWidget);
  });

  testWidgets('a usable Pause is not decorated with a reason', (tester) async {
    await _pump(tester, reason: null, onPause: () async {});

    expect(
      find.ancestor(of: find.text('Pause'), matching: find.byType(Tooltip)),
      findsNothing,
    );
  });
}
