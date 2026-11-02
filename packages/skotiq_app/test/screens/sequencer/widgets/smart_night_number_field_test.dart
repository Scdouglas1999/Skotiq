// The Plan tonight strategy fields dropped typed values unless Enter was
// pressed (qa-night N09), and showed 0.5 h as "1" (N23).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('a typed value counts without Enter, decimals included',
      (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Column(
            children: [
              SmartNightNumberField(
                initial: 4,
                suffix: 'h',
                onChanged: values.add,
              ),
              const TextField(key: Key('other')),
            ],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, '0.5');
    await tester.pump();
    expect(values.last, 0.5, reason: 'no Enter was pressed');

    // Moving on to the next field keeps it, and the field shows 0.5, not 1.
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(values.last, 0.5);
  });

  testWidgets('a fractional initial value is shown as it is', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SmartNightNumberField(
            initial: 0.5,
            suffix: 'h',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('0.5'), findsOneWidget);
  });
}
