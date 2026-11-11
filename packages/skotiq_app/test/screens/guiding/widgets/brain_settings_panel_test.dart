import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(body: SizedBox(width: 520, height: 600, child: child)),
);

void main() {
  testWidgets('edits stay local until Apply and writes are ordered', (
    tester,
  ) async {
    final writes = <({String axis, String name, double value})>[];
    await tester.pumpWidget(
      _wrap(
        BrainSettingsPanel(
          isEditing: true,
          raParams: const [BrainParam(name: 'Aggressiveness', value: 70)],
          decParams: const [BrainParam(name: 'MinMove', value: 0.2)],
          onParamChanged: (axis, name, value) async {
            writes.add((axis: axis, name: name, value: value));
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), '80');
    await tester.enterText(find.byType(TextField).at(1), '0.35');
    await tester.pump();

    expect(writes, isEmpty, reason: 'typing must not issue hardware RPCs');
    expect(find.text('Apply'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(writes, [
      (axis: 'ra', name: 'Aggressiveness', value: 80.0),
      (axis: 'dec', name: 'MinMove', value: 0.35),
    ]);
    expect(find.text('Apply'), findsNothing);
  });

  testWidgets('Reset discards drafts without writing them', (tester) async {
    var writes = 0;
    var resets = 0;
    await tester.pumpWidget(
      _wrap(
        BrainSettingsPanel(
          isEditing: true,
          raParams: const [BrainParam(name: 'Aggressiveness', value: 70)],
          decParams: const [],
          onParamChanged: (_, __, ___) async => writes++,
          onReset: () async => resets++,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '80');
    await tester.pump();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(writes, 0);
    expect(resets, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '70.00',
    );
    expect(find.text('Apply'), findsNothing);
  });

  testWidgets('failed Apply stays retryable and shows the real error', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BrainSettingsPanel(
          isEditing: true,
          raParams: const [BrainParam(name: 'Aggressiveness', value: 70)],
          decParams: const [],
          onParamChanged: (_, __, ___) async {
            throw StateError('PHD2 rejected this value');
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '80');
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('PHD2 rejected this value'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
  });
}
