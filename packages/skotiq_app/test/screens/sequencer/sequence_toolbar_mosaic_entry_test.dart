// The Mosaic Wizard must be reachable from the shipping app.
//
// `MosaicWizardDialog` (visual planner + grid/overlap/filter controls + "Create
// mosaic project", ~1400 lines) had NO production call site: a repo-wide search
// for it returned only its own declaration, a barrel export, two doc comments,
// and four test files. Every one of those tests constructed the dialog directly,
// so the suite reported the whole surface as covered while no user could open it
// — the sequencer toolbar had New Sequence, Quick-Start, Flat, Plan Tonight,
// Open, Import and Save, and no mosaic entry anywhere.
//
// This test asserts the toolbar ENTRY POINT exists and opens the dialog, which
// is the thing the four dialog-level tests could never catch.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_toolbar.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';
import 'canvas_bar_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpToolbar(WidgetTester tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => SequenceToolbar(
          colors: SkotiqColors.of(context),
        ),
      ),
      size: const Size(1600, 900),
    );
  }

  testWidgets('the canvas bar exposes a Plan mosaic action', (tester) async {
    await pumpToolbar(tester);
    await openCanvasBarMenu(tester);

    expect(
      canvasBarAction('Plan mosaic'),
      findsOneWidget,
      reason: 'the mosaic planner had no entry point in the shipping app',
    );
    // The neighbouring wizards are untouched.
    expect(canvasBarAction('Quick-start wizard'), findsOneWidget);
    expect(canvasBarAction('Plan tonight'), findsOneWidget);
  });

  testWidgets('tapping Plan mosaic opens the mosaic wizard', (tester) async {
    await pumpToolbar(tester);

    expect(find.byType(MosaicWizardDialog), findsNothing);
    await tapCanvasBarAction(tester, 'Plan mosaic');

    expect(
      find.byType(MosaicWizardDialog),
      findsOneWidget,
      reason: 'the entry point must actually open the planner',
    );
  });
}
