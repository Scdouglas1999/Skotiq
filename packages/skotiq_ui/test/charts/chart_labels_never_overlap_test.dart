// Tick labels stay legible at any size.
//
// A phone guiding layout leaves the plot under 20 px tall. Five value labels
// drawn there unconditionally land on top of each other, so the chart thins
// them to a stride that keeps both ends, and to none when even the ends
// would touch. Canvas text leaves nothing in the widget tree, so this records
// the paragraphs the painter draws.
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

Future<CustomPainter> _painter(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 300,
          child: SkotiqChart(
            semanticLabel: 'Guide error',
            series: const <ChartSeries>[],
            x: const ChartAxis(kind: ChartAxisKind.elapsed, min: -300, max: 0),
            y: ChartAxis(
              min: -2,
              max: 2,
              ticks: const <double>[-2, -1, 0, 1, 2],
              format: (v) => v == 0 ? '0' : '${v > 0 ? '+' : ''}${v.round()}"',
            ),
          ),
        ),
      ),
    ),
  );
  return tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<CustomPainter>()
      .firstWhere((p) => p.runtimeType.toString() == '_ChartPainter');
}

void main() {
  for (final height in <double>[10, 20, 30, 45, 60, 120, 300]) {
    testWidgets('no two labels overlap at ${height}px', (tester) async {
      final painter = await _painter(tester);
      final canvas = _RecordingCanvas();
      painter.paint(canvas, Size(360, height));
      final rects = canvas.paragraphs;
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(
            rects[i].deflate(0.5).overlaps(rects[j].deflate(0.5)),
            isFalse,
            reason: 'labels $i and $j overlap at ${height}px: $rects',
          );
        }
      }
    });
  }

  testWidgets('thinned value labels keep both ends of the scale', (
    tester,
  ) async {
    final painter = await _painter(tester);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(360, 60));
    // Value labels sit in the left gutter, above the time labels' row.
    final time = canvas.paragraphs
        .map((r) => r.top)
        .reduce((a, b) => a > b ? a : b);
    final values = canvas.paragraphs.where((r) => r.top < time).toList();
    expect(values, isNotEmpty);
    expect(values.length.isOdd, isTrue, reason: 'symmetric about zero');
  });
}
