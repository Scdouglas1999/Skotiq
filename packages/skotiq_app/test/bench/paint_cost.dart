// Measures what one repaint of a chart costs: every leaf that draws under a
// widget (custom painters, fl_chart render objects, text) is painted into a
// fresh picture, many times, and the median is reported.
//
// Run by hand: flutter test test/bench/chart_paint_cost_test.dart
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Context extends PaintingContext {
  _Context(super.containerLayer, super.estimatedBounds);

  void finish() => stopRecordingIfNeeded();
}

List<RenderObject> _drawingLeaves(RenderObject root) {
  final out = <RenderObject>[];
  void visit(RenderObject node) {
    final name = node.runtimeType.toString();
    if (node is RenderParagraph ||
        node is RenderCustomPaint ||
        name.contains('Chart')) {
      out.add(node);
    }
    node.visitChildren(visit);
  }

  visit(root);
  return out;
}

/// Median microseconds for one paint of everything that draws under [finder].
double medianPaintMicros(
  WidgetTester tester,
  Finder finder, {
  int warmup = 60,
  int runs = 300,
}) {
  final root = tester.renderObject(finder);
  final leaves = _drawingLeaves(root);
  expect(leaves, isNotEmpty);

  void paintOnce() {
    for (final leaf in leaves) {
      if (leaf is RenderCustomPaint) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        leaf.painter?.paint(canvas, leaf.size);
        leaf.foregroundPainter?.paint(canvas, leaf.size);
        recorder.endRecording().dispose();
      } else {
        final context = _Context(ContainerLayer(), leaf.paintBounds);
        leaf.paint(context, Offset.zero);
        context.finish();
      }
    }
  }

  for (var i = 0; i < warmup; i++) {
    paintOnce();
  }
  final samples = <int>[];
  final watch = Stopwatch();
  for (var i = 0; i < runs; i++) {
    watch
      ..reset()
      ..start();
    paintOnce();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2].toDouble();
}
