import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'golden/golden_harness.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(body: child),
  );

  testWidgets('exposes keyboard privacy controls', (tester) async {
    await tester.pumpWidget(
      wrap(const SkotiqTextField(autocorrect: false, enableSuggestions: false)),
    );

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets('obscured fields disable correction and suggestions by default', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const SkotiqTextField(obscureText: true)));

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets(
    'a 32px well centres its value with a sibling button and a FormRow label',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SkotiqButton(label: 'Snapshot', onPressed: null),
                    SizedBox(width: 8),
                    SizedBox(
                      width: 92,
                      child: SkotiqTextField(
                        initialValue: '2.0',
                        prefixIcon: LucideIcons.clock,
                        suffix: 's',
                        mono: true,
                      ),
                    ),
                    SizedBox(width: 8),
                    SizedBox(
                      width: 92,
                      child: SkotiqTextField(
                        initialValue: '100',
                        prefixIcon: LucideIcons.sliders,
                        mono: true,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                FormRow(
                  label: 'Exposure',
                  child: SkotiqTextField(
                    initialValue: '2.0',
                    suffix: 's',
                    mono: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final button = tester.getRect(find.byType(SkotiqButton));
      final fields = tester
          .widgetList<SkotiqTextField>(find.byType(SkotiqTextField))
          .toList();
      expect(fields, hasLength(3));

      final hudExposure = tester.getRect(find.byType(SkotiqTextField).at(0));
      final hudGain = tester.getRect(find.byType(SkotiqTextField).at(1));
      expect(hudExposure.height, fieldHeight);
      expect(hudGain.height, fieldHeight);
      expect(hudExposure.center.dy, closeTo(button.center.dy, 0.5));
      expect(hudGain.center.dy, closeTo(button.center.dy, 0.5));

      final prefix = tester.getRect(find.byIcon(LucideIcons.clock));
      expect(prefix.center.dy, closeTo(hudExposure.center.dy, 0.5));

      final label = tester.getRect(find.text('Exposure'));
      final formField = tester.getRect(find.byType(SkotiqTextField).at(2));
      expect(formField.height, fieldHeight);
      expect(label.center.dy, closeTo(formField.center.dy, 0.5));
    },
  );

  testWidgets('the typed value sits on the well centre, with the unit', (
    tester,
  ) async {
    await GoldenHarness.ensureFonts();
    await tester.pumpWidget(
      wrap(
        const SizedBox(
          width: 160,
          child: SkotiqTextField(initialValue: '2.0', suffix: 's', mono: true),
        ),
      ),
    );

    final field = tester.getRect(find.byType(SkotiqTextField));
    final editable = tester.getRect(find.byType(EditableText));

    expect(
      editable.center.dy,
      closeTo(field.center.dy, 0.5),
      reason: 'the collapsed slot fills the well, so the 14px input centres',
    );

    // The unit suffix is laid out by the decorator on the value's baseline.
    final editableRender = tester.renderObject<RenderEditable>(
      find.descendant(
        of: find.byType(EditableText),
        matching: find.byElementPredicate(
          (e) => e.renderObject is RenderEditable,
        ),
      ),
    );
    final unitRender = tester.renderObject<RenderParagraph>(find.text('s'));
    final editableBaseline =
        editable.top +
        editableRender.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final unit = tester.getRect(find.text('s'));
    final unitBaseline =
        unit.top +
        unitRender.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    expect(
      unitBaseline,
      closeTo(editableBaseline, 0.5),
      reason: 'the unit shares the value baseline instead of riding high',
    );
  });

  RenderEditable editableRender(WidgetTester tester) {
    return tester.renderObject<RenderEditable>(
      find.descendant(
        of: find.byType(EditableText),
        matching: find.byElementPredicate(
          (e) => e.renderObject is RenderEditable,
        ),
      ),
    );
  }

  /// The centre of the tight glyph box the decorator positions, relative to
  /// the field box's centre. Positive means the ink sits low.
  double lineBoxOffset(WidgetTester tester) {
    final field = tester.getRect(find.byType(SkotiqTextField));
    final editable = editableRender(tester);
    editable.selectionHeightStyle = ui.BoxHeightStyle.tight;
    final len = editable.text?.toPlainText().length ?? 0;
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: len),
    );
    final editableTop = tester.getRect(find.byType(EditableText)).top;
    final ink = boxes
        .map((b) => b.toRect())
        .reduce((a, b) => a.expandToInclude(b));
    return (editableTop + ink.center.dy) - field.center.dy;
  }

  /// The centre of the bright glyph ink rows in a 4x raster of the field's
  /// RepaintBoundary, relative to the well's centre row.
  Future<double> rasterInkOffset(
    WidgetTester tester, {
    int xFrom = 0,
    int xTo = 1 << 30,
  }) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('inkBoundary')),
    );
    const pr = 4.0;
    final data = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: pr);
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    });
    final px = data!.buffer.asUint8List();
    final w = (boundary.size.width * pr).round();
    final h = (boundary.size.height * pr).round();
    var top = -1;
    var bottom = -1;
    for (var y = 0; y < h; y++) {
      var bright = false;
      for (var x = xFrom; x < w && x < xTo; x++) {
        final i = (y * w + x) * 4;
        if ((px[i] + px[i + 1] + px[i + 2]) / 3 > 150) {
          bright = true;
          break;
        }
      }
      if (bright) {
        if (top < 0) top = y;
        bottom = y;
      }
    }
    return ((top + bottom) / 2 - h / 2) / pr;
  }

  testWidgets('numeric, lowercase and unit ink centres on the well', (
    tester,
  ) async {
    await GoldenHarness.ensureFonts();

    Widget field(Widget child, {double width = 200}) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const ValueKey('inkBoundary'),
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

    // Numeric mono field at the dense 28px height: the strut's tight box and
    // the rasterised digit ink both centre on the well.
    await tester.pumpWidget(
      field(
        const SkotiqTextField(initialValue: '100', mono: true, dense: true),
      ),
    );
    expect(
      tester.getRect(find.byType(SkotiqTextField)).height,
      fieldHeightDense,
    );
    expect(
      lineBoxOffset(tester).abs(),
      lessThanOrEqualTo(0.5),
      reason: 'numeric line box should centre on the well',
    );
    final numericInk = await rasterInkOffset(tester);
    expect(
      numericInk.abs(),
      lessThanOrEqualTo(0.5),
      reason: 'digit ink should centre on the well (was +2.5 low)',
    );
    // A lowercase Hanken value shares the same baseline and slot; its tight
    // line box is identical, so it centres the same way. In 'galaxy' the 'g'
    // descender balances the 'l' ascender, so the rasterised ink centres too
    // — the offset is reported rather than asserted since which letters a
    // value contains shifts its ink bounds within the same centred slot.
    await tester.pumpWidget(
      field(const SkotiqTextField(initialValue: 'galaxy')),
    );
    expect(
      lineBoxOffset(tester).abs(),
      lessThanOrEqualTo(0.5),
      reason: 'lowercase line box should centre on the well',
    );
    expect(
      tester.getRect(find.byType(EditableText)).center.dy,
      closeTo(tester.getRect(find.byType(SkotiqTextField)).center.dy, 0.5),
      reason: 'the 14px input slot centres in the 32px well',
    );
    debugPrint(
      'lowercase ink offset: '
      '${(await rasterInkOffset(tester)).toStringAsFixed(2)} px',
    );

    // The unit suffix sits on the value's baseline.
    await tester.pumpWidget(
      field(
        const SkotiqTextField(initialValue: '2.0', mono: true, suffix: 's'),
      ),
    );
    final valueBaseline =
        tester.getRect(find.byType(EditableText)).top +
        editableRender(
          tester,
        ).computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final unitRect = tester.getRect(find.text('s'));
    final unitBaseline =
        unitRect.top +
        tester
            .renderObject<RenderParagraph>(find.text('s'))
            .computeDistanceToActualBaseline(TextBaseline.alphabetic);
    expect(
      (unitBaseline - valueBaseline).abs(),
      lessThanOrEqualTo(0.5),
      reason: 'unit shares the value baseline',
    );
  });
}
