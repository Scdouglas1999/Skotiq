import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpAt(WidgetTester tester, double width, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Align(alignment: Alignment.topCenter, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a menu chip opens its choices and reports the one picked', (
    tester,
  ) async {
    String? picked;
    await _pumpAt(
      tester,
      800,
      SkotiqMenuChip<String>(
        label: 'Sort: Score',
        value: 'score',
        choices: const [
          SkotiqMenuChoice('score', 'Score'),
          SkotiqMenuChoice('altitude', 'Altitude'),
        ],
        onSelected: (value) => picked = value,
      ),
    );

    await tester.tap(find.text('Sort: Score'));
    await tester.pumpAndSettle();
    final chip = tester.getRect(find.byType(SkotiqFilterChip));
    final item = tester.getRect(find.text('Altitude'));
    expect(
      item.top,
      greaterThanOrEqualTo(chip.bottom),
      reason: 'the menu opens below the chip, not over it',
    );

    await tester.tap(find.text('Altitude'));
    await tester.pumpAndSettle();
    expect(picked, 'altitude');
  });
}
