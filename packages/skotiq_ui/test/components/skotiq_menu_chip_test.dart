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
        entries: const [
          SkotiqMenuChoice('score', 'Score', checked: true),
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

  testWidgets('a null value is a pick, not a dismissal', (tester) async {
    final picks = <int?>[];
    await _pumpAt(
      tester,
      800,
      SkotiqMenuChip<int?>(
        label: 'Status: done',
        name: 'Status',
        entries: const [
          SkotiqMenuChoice(null, 'Any status'),
          SkotiqMenuDivider(),
          SkotiqMenuChoice(1, 'Done', checked: true),
        ],
        onSelected: picks.add,
      ),
    );
    expect(
      find.bySemanticsLabel('Status: Status: done'),
      findsOneWidget,
      reason: 'a screen reader hears what the control is, then its value',
    );

    await tester.tap(find.text('Status: done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any status'));
    await tester.pumpAndSettle();
    expect(picks, [null]);

    await tester.tap(find.text('Status: done'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 395));
    await tester.pumpAndSettle();
    expect(picks, [null], reason: 'dismissing the menu picks nothing');
  });

  testWidgets('a phone-width chip has a 48 px hit area', (tester) async {
    await _pumpAt(
      tester,
      390,
      SkotiqMenuChip<int>(
        label: 'Sort: name',
        roomy: true,
        entries: const [SkotiqMenuChoice(1, 'Name')],
        onSelected: (_) {},
      ),
    );
    expect(
      tester.getSize(find.byType(GestureDetector).first).height,
      SkotiqTokens.minTouchTarget,
    );
  });

  testWidgets('a menu button reports the row picked', (tester) async {
    String? picked;
    await _pumpAt(
      tester,
      800,
      SkotiqMenuButton<String>(
        tooltip: 'More actions for M31',
        entries: const [
          SkotiqMenuChoice('duplicate', 'Duplicate'),
          SkotiqMenuChoice('delete', 'Delete', destructive: true),
        ],
        onSelected: (value) => picked = value,
      ),
    );
    await tester.tap(find.byType(SkotiqIconButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(picked, 'delete');
  });
}
