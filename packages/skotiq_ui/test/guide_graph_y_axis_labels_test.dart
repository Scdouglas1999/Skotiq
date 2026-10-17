// The guide graph's Y-axis labels stay legible.
//
// The phone guiding layout leaves the plot area very short (panel header +
// scale-selector row + gutters take a fixed slice of the graph pane), so a
// painter that draws all five labels — +2" / +1.0" / 0 / -1.0" / -2" —
// unconditionally lands them on top of each other as an illegible smear at
// the left edge.
//
// The painter's own text drawing is invisible to the widget tree, so this
// captures the `drawParagraph` calls the painter makes and asserts the label
// rects never overlap.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Canvas stand-in that records every paragraph the painter draws.
class _RecordingCanvas implements Canvas {
  final List<Rect> paragraphs = [];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    paragraphs.add(offset & Size(paragraph.longestLine, paragraph.height));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Every rect the painter drew that sits in the Y-axis gutter (drawn at x = 2,
/// left of the plot area, versus the X-axis labels which start at the plot's
/// left margin).
List<Rect> _yAxisLabels(_RecordingCanvas canvas) =>
    canvas.paragraphs.where((r) => r.left < 4).toList()
      ..sort((a, b) => a.top.compareTo(b.top));

Future<CustomPainter> _graphPainter(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(
        body: SizedBox(
          width: 360,
          height: 300,
          child: GuideGraphAdvanced(data: []),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final painted = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<CustomPainter>()
      .where((p) => p.runtimeType.toString().contains('GraphPainter'))
      .toList();
  expect(
    painted,
    hasLength(1),
    reason: 'Expected exactly one guide-graph painter.',
  );
  return painted.single;
}

void main() {
  // Heights of the CustomPaint box. The guiding screen on a 411x914 phone
  // hands the plot roughly 20-45 px once the panel chrome is taken out; the
  // taller entries cover a roomier tablet/desktop pane.
  for (final height in <double>[10, 20, 30, 45, 60, 120, 300]) {
    testWidgets('guide graph Y-axis labels never overlap at ${height}px', (
      tester,
    ) async {
      final painter = await _graphPainter(tester);
      final canvas = _RecordingCanvas();
      painter.paint(canvas, Size(360, height));

      final labels = _yAxisLabels(canvas);
      for (var i = 1; i < labels.length; i++) {
        expect(
          labels[i].top,
          greaterThanOrEqualTo(labels[i - 1].bottom),
          reason:
              'Y-axis label $i overlaps label ${i - 1} at ${height}px '
              '(${labels.map((r) => r.top.toStringAsFixed(1)).join(", ")}).',
        );
      }
    });
  }

  testWidgets('guide graph keeps both scale extremes while any label fits', (
    tester,
  ) async {
    final painter = await _graphPainter(tester);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(360, 60));

    final labels = _yAxisLabels(canvas);
    expect(
      labels,
      isNotEmpty,
      reason: 'A 60px plot has room for the extremes and zero.',
    );
    expect(
      labels.length.isOdd,
      isTrue,
      reason: 'Thinning must stay symmetric about the zero line.',
    );
  });
}
