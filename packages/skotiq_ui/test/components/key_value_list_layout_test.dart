import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(WidgetTester tester, String value, double width) =>
    tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: KeyValueList(rows: [('Auto-resume', value)]),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a short value sits at the right edge', (tester) async {
    await _pump(tester, 'Disabled', 320);
    expect(tester.getTopRight(find.text('Disabled')).dx, 320);
  });

  testWidgets('a long value wraps inside the row instead of overflowing', (
    tester,
  ) async {
    await _pump(tester, 'Off while safety is off', 200);
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopRight(find.text('Off while safety is off')).dx,
      lessThanOrEqualTo(200),
    );
  });
}
