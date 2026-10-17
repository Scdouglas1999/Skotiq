// One HFR sparkline, drawn the same way up on every Run-dashboard surface.
//
// The dashboard carried two `_HfrSparklinePainter` classes — one in
// `quality_panel.dart`, one in `live_frame_panel.dart` — with the same name and
// the same purpose. They disagreed on the flat-series clamp (1e-3 vs 1e-6), on
// the stroke width, and on which way up the trend was drawn: the quality
// panel's `y = height * (1 - normalized)` put the LOWEST HFR at the BOTTOM,
// contradicting its own comment ("smaller HFR draws at the top") and mirroring
// the live-frame badge next to it. Both comments agree on the intent, so the
// merged painter takes the orientation both files documented.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/hfr_sparkline.dart';

/// Captures the geometry a painter draws. Only the members the sparkline uses
/// are overridden; anything else it reached for would throw rather than pass
/// silently.
class _RecordingCanvas implements Canvas {
  final List<(Path, Paint)> paths = [];
  final List<(Offset, double, Paint)> circles = [];

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint));

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((c, radius, paint));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'unexpected canvas call: ${invocation.memberName}');
}

/// First and last vertex of a polyline path.
(Offset, Offset) _endpoints(Path path) {
  final metric = path.computeMetrics().first;
  final start = metric.getTangentForOffset(0)!.position;
  final end = metric.getTangentForOffset(metric.length)!.position;
  return (start, end);
}

void main() {
  const size = Size(100, 100);

  test('lower HFR is drawn higher on screen', () {
    final canvas = _RecordingCanvas();
    // Ascending HFR: focus getting worse over the run.
    const HfrSparklinePainter(
      values: [2.0, 3.0, 4.0],
      color: Color(0xFF00FF00),
    ).paint(canvas, size);

    expect(canvas.paths, hasLength(1), reason: 'stroke only, no fill');
    final (first, last) = _endpoints(canvas.paths.single.$1);

    expect(first.dy, lessThan(last.dy),
        reason: 'HFR 2.0 is better focus than 4.0, so it belongs above it — '
            'the quality panel drew this pair upside down');
    expect(first.dy, closeTo(0, 0.01));
    expect(last.dy, closeTo(size.height, 0.01));
    expect(first.dx, closeTo(0, 0.01));
    expect(last.dx, closeTo(size.width, 0.01));
  });

  test('a flat series draws a level line instead of dividing by zero', () {
    final canvas = _RecordingCanvas();
    const HfrSparklinePainter(
      values: [3.0, 3.0, 3.0],
      color: Color(0xFF00FF00),
    ).paint(canvas, size);

    final (first, last) = _endpoints(canvas.paths.single.$1);
    expect(first.dy, closeTo(0, 0.01));
    expect(last.dy, closeTo(0, 0.01));
    expect(first.dy.isNaN, isFalse);
  });

  test('fewer than two points paints nothing', () {
    final canvas = _RecordingCanvas();
    const HfrSparklinePainter(values: [3.0], color: Color(0xFF00FF00))
        .paint(canvas, size);
    expect(canvas.paths, isEmpty);
    expect(canvas.circles, isEmpty);
  });

  test('rejected frames get a dot at their own point (quality-panel mode)', () {
    final canvas = _RecordingCanvas();
    const HfrSparklinePainter(
      values: [2.0, 3.0, 4.0],
      accepted: [true, false, true],
      color: Color(0xFF00FF00),
      rejectColor: Color(0xFFFF0000),
    ).paint(canvas, size);

    expect(canvas.circles, hasLength(1));
    final (centre, radius, paint) = canvas.circles.single;
    expect(paint.color.toARGB32(), const Color(0xFFFF0000).toARGB32());
    expect(radius, 2.5);
    expect(centre.dx, closeTo(size.width / 2, 0.01));
    expect(centre.dy, closeTo(size.height / 2, 0.01));
  });

  test('the accept list is ignored when it does not match the values', () {
    final canvas = _RecordingCanvas();
    const HfrSparklinePainter(
      values: [2.0, 3.0, 4.0],
      accepted: [false],
      color: Color(0xFF00FF00),
      rejectColor: Color(0xFFFF0000),
    ).paint(canvas, size);
    expect(canvas.circles, isEmpty);
  });

  test('the badge mode fills under the line and marks the newest point', () {
    final canvas = _RecordingCanvas();
    const HfrSparklinePainter(
      values: [2.0, 3.0, 4.0],
      color: Color(0xFF00FF00),
      fillColor: Color(0x2200FF00),
      showLatestMarker: true,
    ).paint(canvas, size);

    expect(canvas.paths, hasLength(2), reason: 'fill first, then the stroke');
    final fill = canvas.paths.first;
    // `Paint.color` round-trips through float components, so compare the
    // packed value rather than the Color object.
    expect(fill.$2.color.toARGB32(), const Color(0x2200FF00).toARGB32());
    expect(fill.$2.style, PaintingStyle.fill);
    expect(fill.$1.getBounds().bottom, closeTo(size.height, 0.01),
        reason: 'the fill is closed down to the baseline');

    expect(canvas.circles, hasLength(1));
    final (centre, _, paint) = canvas.circles.single;
    expect(paint.color.toARGB32(), const Color(0xFF00FF00).toARGB32());
    expect(centre.dx, closeTo(size.width, 0.01),
        reason: 'the marker sits on the newest sample');
    expect(centre.dy, closeTo(size.height, 0.01));
  });

  test('shouldRepaint tracks every input', () {
    const base = HfrSparklinePainter(
      values: [2.0, 3.0],
      color: Color(0xFF00FF00),
    );
    expect(base.shouldRepaint(base), isFalse);
    expect(
      base.shouldRepaint(
        const HfrSparklinePainter(values: [2.0, 9.0], color: Color(0xFF00FF00)),
      ),
      isTrue,
    );
    expect(
      base.shouldRepaint(
        const HfrSparklinePainter(
          values: [2.0, 3.0],
          color: Color(0xFF00FF00),
          showLatestMarker: true,
        ),
      ),
      isTrue,
    );
  });
}
