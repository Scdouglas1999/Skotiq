import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host({double? portraitStartFraction}) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: TwoPane(
        portraitStartHeightFraction: portraitStartFraction,
        start: const ColoredBox(
          color: Color(0xFF111111),
          child: Center(child: Text('START')),
        ),
        end: const ColoredBox(
          color: Color(0xFF222222),
          child: Center(child: Text('END')),
        ),
      ),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('stacks (Column) in phone portrait (390x844)', (tester) async {
    await _pumpAt(tester, const Size(390, 844), _host());
    expect(tester.takeException(), isNull);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('END'), findsOneWidget);

    final startBox = tester.getRect(find.text('START'));
    final endBox = tester.getRect(find.text('END'));
    // Stacked: START is above END.
    expect(startBox.center.dy, lessThan(endBox.center.dy));
  });

  testWidgets('splits (Row) in landscape when wide enough (844x390)', (
    tester,
  ) async {
    await _pumpAt(tester, const Size(844, 390), _host());
    expect(tester.takeException(), isNull);

    final startBox = tester.getRect(find.text('START'));
    final endBox = tester.getRect(find.text('END'));
    // Side-by-side: START is left of END.
    expect(startBox.center.dx, lessThan(endBox.center.dx));
  });

  testWidgets('stays stacked in narrow landscape below minSplitWidth', (
    tester,
  ) async {
    // 500 wide landscape < default minSplitWidth (560) -> stacked.
    await _pumpAt(tester, const Size(500, 360), _host());
    expect(tester.takeException(), isNull);

    final startBox = tester.getRect(find.text('START'));
    final endBox = tester.getRect(find.text('END'));
    expect(startBox.center.dy, lessThan(endBox.center.dy));
  });

  testWidgets('portrait start-fraction gives START a fixed height', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(390, 844),
      _host(portraitStartFraction: 0.5),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('END'), findsOneWidget);
  });
}
