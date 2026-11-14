// Reads what a SkotiqChart paints. Canvas text leaves nothing in the widget
// tree, so a test that cares where the tick labels land records the
// paragraphs the chart's painter draws.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _RecordingCanvas implements Canvas {
  final List<Rect> paragraphs = <Rect>[];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add(offset & Size(paragraph.longestLine, paragraph.height));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The rectangle of every label the chart found by [chart] paints at its
/// laid-out size.
List<Rect> chartLabelRects(WidgetTester tester, Finder chart) {
  final paint = tester
      .widgetList<CustomPaint>(
        find.descendant(of: chart, matching: find.byType(CustomPaint)),
      )
      .firstWhere((w) => w.painter.runtimeType.toString() == '_ChartPainter');
  final size = tester.getSize(
    find.byWidgetPredicate((w) => identical(w, paint)),
  );
  final canvas = _RecordingCanvas();
  paint.painter!.paint(canvas, size);
  return canvas.paragraphs;
}

/// Fails when two labels the chart paints overlap.
void expectNoOverlappingChartLabels(WidgetTester tester, Finder chart) {
  final rects = chartLabelRects(tester, chart);
  expect(rects.length, greaterThan(2));
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      expect(
        rects[i].deflate(0.5).overlaps(rects[j].deflate(0.5)),
        isFalse,
        reason: 'label $i ${rects[i]} overlaps label $j ${rects[j]}',
      );
    }
  }
}

/// The layout (ranges and ticks) of the chart found by [chart].
ChartLayout chartLayoutOf(WidgetTester tester, Finder chart) {
  final widget = tester.widget<SkotiqChart>(chart);
  return ChartLayout(
    series: widget.series,
    x: widget.x,
    y: widget.y,
    y2: widget.y2,
    rules: widget.rules,
    dense: widget.dense,
  );
}
