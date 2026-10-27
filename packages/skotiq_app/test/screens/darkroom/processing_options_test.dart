import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/processing_options_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('operator can choose local normalization and all drizzle scales',
      (tester) async {
    var value = const DarkroomProcessingOptions();
    await tester.pumpWidget(MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
              builder: (context, setState) => SizedBox(
                    width: 380,
                    child: ProcessingOptionsPanel(
                        value: value,
                        width: 4656,
                        height: 3520,
                        frames: 100,
                        onChanged: (v) => setState(() => value = v)),
                  )),
        )));
    await tester.tap(find.byKey(const ValueKey('processing_normalization')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local').last);
    await tester.pumpAndSettle();
    expect(value.normalization, 'local');
    for (final scale in [1, 2, 3, 4]) {
      await tester.tap(find.byKey(const ValueKey('processing_drizzle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$scale× drizzle').last);
      await tester.pumpAndSettle();
      expect(value.drizzleScale, scale);
    }
    expect(find.textContaining('18624 × 14080'), findsOneWidget);
    expect(find.textContaining('16×'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
