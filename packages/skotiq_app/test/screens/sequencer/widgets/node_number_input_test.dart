import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_property_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Future<List<double>> pumpField(WidgetTester tester) async {
    final committed = <double>[];
    var value = 5.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                NodeNumberInput(
                  colors: SkotiqColors.dark,
                  value: value,
                  min: 0,
                  max: 100,
                  onChanged: (v) {
                    committed.add(v);
                    setState(() => value = v);
                  },
                ),
                const TextField(key: ValueKey('next')),
              ],
            ),
          ),
        ),
      ),
    );
    return committed;
  }

  testWidgets('a value typed and left at once is kept', (tester) async {
    final committed = await pumpField(tester);

    await tester.enterText(find.byType(TextField).first, '8');
    // Leave the field well inside the commit debounce.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('next')));
    await tester.pump();

    expect(committed, [8]);
    expect(find.text('8'), findsOneWidget);

    // The debounce that was cut short commits nothing more.
    await tester.pump(kNumberInputCommitDebounce * 2);
    expect(committed, [8]);
    expect(find.text('8'), findsOneWidget);
  });

  testWidgets('a value typed and left alone commits after the debounce', (
    tester,
  ) async {
    final committed = await pumpField(tester);

    await tester.enterText(find.byType(TextField).first, '12');
    await tester.pump(kNumberInputCommitDebounce);
    expect(committed, [12]);

    await tester.tap(find.byKey(const ValueKey('next')));
    await tester.pump();
    expect(committed, [12]);
    expect(find.text('12'), findsOneWidget);
  });

  testWidgets(
    'tapping a non-focusable action button inside the debounce commits first',
    (tester) async {
      final committed = <double>[];
      double? valueSeenOnSave;
      var value = 5.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  NodeNumberInput(
                    colors: SkotiqColors.dark,
                    value: value,
                    min: 0,
                    max: 100,
                    onChanged: (v) {
                      committed.add(v);
                      setState(() => value = v);
                    },
                  ),
                  GestureDetector(
                    key: const ValueKey('save'),
                    onTap: () => valueSeenOnSave = value,
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).first, '42');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('save')));
      await tester.pump();

      expect(committed, [42]);
      expect(valueSeenOnSave, 42);

      await tester.pump(kNumberInputCommitDebounce * 2);
      expect(committed, [42]);
    },
  );

  testWidgets('submitting with Enter commits immediately inside the debounce', (
    tester,
  ) async {
    final committed = await pumpField(tester);

    await tester.enterText(find.byType(TextField).first, '27');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(committed, [27]);
    await tester.pump(kNumberInputCommitDebounce * 2);
    expect(committed, [27]);
  });
}
