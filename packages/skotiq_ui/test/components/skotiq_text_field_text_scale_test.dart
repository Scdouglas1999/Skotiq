// A single-line field keeps its whole line at a larger text size.
//
// The value's slot was a fixed 14 px box (the unscaled font size), so at
// 1.3x text the 18 px line, the placeholder included, was cut off at the
// bottom inside the well.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pump(WidgetTester tester, double scale) => tester.pumpWidget(
  MaterialApp(
    theme: SkotiqTheme.dark,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: const Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            child: SkotiqTextField(hint: 'RA 01h 36m'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final scale in <double>[1.0, 1.3, 2.0]) {
    testWidgets('the line fits at ${scale}x text', (tester) async {
      await _pump(tester, scale);
      // One line of the value's style at this text size, laid out freely.
      final line = TextPainter(
        text: TextSpan(
          text: 'RA 01h 36m',
          style: SkotiqTypography.input.copyWith(height: 1.0),
        ),
        textScaler: TextScaler.linear(scale),
        textDirection: TextDirection.ltr,
      )..layout();
      addTearDown(line.dispose);
      final editable = tester.getRect(find.byType(EditableText));
      // Half a pixel of slack for the line box's pixel snapping.
      expect(
        editable.height,
        greaterThanOrEqualTo(line.height - 0.5),
        reason: 'the value slot must hold one line at this text size',
      );
      final hint = tester.getRect(find.text('RA 01h 36m'));
      final well = tester.getRect(find.byType(SkotiqTextField));
      expect(hint.top, greaterThanOrEqualTo(well.top));
      expect(
        hint.bottom,
        lessThanOrEqualTo(well.bottom),
        reason: 'the placeholder must sit inside the well',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
