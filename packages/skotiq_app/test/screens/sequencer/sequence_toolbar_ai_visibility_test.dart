import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sequencer toolbar hides the conversational AI builder action',
      (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(
          colors: SkotiqColors.of(context),
        ),
      ),
      size: const Size(1600, 900),
    );

    await openCanvasBarMenu(tester);
    expect(canvasBarAction('Quick-start wizard'), findsOneWidget);
    expect(canvasBarAction('Plan tonight'), findsOneWidget);
    expect(canvasBarAction('Conversational Builder (AI)'), findsNothing);
  });
}
