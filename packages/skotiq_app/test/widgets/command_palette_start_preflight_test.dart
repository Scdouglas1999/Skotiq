// The palette's "Start sequence" goes through pre-flight like every other
// interactive Start: it opens the pre-flight dialog instead of
// starting the run.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/preflight_validation_dialog.dart';
import 'package:skotiq_app/screens/shell/command_palette/command_palette.dart';

import '../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Start sequence opens the pre-flight checks', (tester) async {
    await pumpAppScreen(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showCommandPalette(context),
            child: const Text('palette'),
          ),
        ),
      ),
      size: const Size(1920, 1080),
    );
    await tester.tap(find.text('palette'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Start sequence');
    await tester.pump();
    await tester.tap(find.text('Start sequence').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PreFlightValidationDialog), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}
