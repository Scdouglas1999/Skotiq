// The promoted V-curve chart has to draw TWO curves on shared axes, because
// the focuser-backlash measurement IS the horizontal gap between their fitted
// vertices. Two independently scaled charts, or one merged point list, would
// each destroy the only thing worth looking at.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart' show VCurvePoint;
import 'package:skotiq_ui/skotiq_ui.dart';

/// A canvas that records what a painter asked for, so the test can assert on
/// marks rather than on pixels.
class _RecordingCanvas implements Canvas {
  final List<Offset> circles = <Offset>[];
  final List<double> circleRadii = <double>[];
  final List<(Offset, Offset)> lines = <(Offset, Offset)>[];
  int paths = 0;

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circles.add(c);
    circleRadii.add(radius);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2));

  @override
  void drawPath(Path path, Paint paint) => paths++;

  @override
  void noSuchMethod(Invocation invocation) {}
}

// The owner's ZWO EAF near position 6600 on 2026-09-14: the from-below scan
// fitted 6620, the from-above scan 6515. 105 steps.
const _belowPoints = <VCurvePoint>[
  VCurvePoint(position: 6500, hfr: 5.1),
  VCurvePoint(position: 6560, hfr: 3.4),
  VCurvePoint(position: 6620, hfr: 2.1),
  VCurvePoint(position: 6680, hfr: 3.6),
  VCurvePoint(position: 6740, hfr: 5.3),
];
const _abovePoints = <VCurvePoint>[
  VCurvePoint(position: 6740, hfr: 5.6),
  VCurvePoint(position: 6680, hfr: 4.0),
  VCurvePoint(position: 6620, hfr: 2.6),
  VCurvePoint(position: 6560, hfr: 2.3),
  VCurvePoint(position: 6500, hfr: 3.9),
];

VCurvePainter _twoCurves({bool guides = true}) => VCurvePainter(
  series: [
    VCurveSeries(
      points: _belowPoints,
      color: SkotiqChartColors.seriesBlue,
      label: 'From below',
      vertexPosition: 6620,
      showVertexGuide: guides,
    ),
    VCurveSeries(
      points: _abovePoints,
      color: SkotiqChartColors.seriesAmber,
      label: 'From above',
      vertexPosition: 6515,
      showVertexGuide: guides,
    ),
  ],
  gridColor: SkotiqColors.dark.border,
  textColor: SkotiqColors.dark.textMuted,
  density: VCurveChartDensity.expanded,
);

void main() {
  const size = Size(600, 240);

  group('VCurvePainter', () {
    test('draws a line per series', () {
      final canvas = _RecordingCanvas();
      // Two polylines plus the diamond marking the 6515 vertex, which falls
      // between samples.
      _twoCurves().paint(canvas, size);
      expect(canvas.paths, 3);

      final plain = _RecordingCanvas();
      _twoCurves(guides: false).paint(plain, size);
      expect(plain.paths, 2);
    });

    test('draws every sample of both series', () {
      final canvas = _RecordingCanvas();
      _twoCurves().paint(canvas, size);
      // Five samples each; the 6620 sample of the from-below scan is its
      // vertex, so it is drawn as a filled dot plus a ring.
      expect(
        canvas.circles.length,
        _belowPoints.length + _abovePoints.length + 1,
      );
    });

    test('marks a vertex that lands on a sample with a ring', () {
      final canvas = _RecordingCanvas();
      _twoCurves().paint(canvas, size);
      expect(canvas.circleRadii, contains(8.0));
    });

    test('marks an off-sample vertex with a full-height guide', () {
      final canvas = _RecordingCanvas();
      _twoCurves().paint(canvas, size);
      // 6515 is between samples, so it gets a vertical guide rather than a
      // ringed data point: nothing was ever exposed at 6515.
      final verticals = canvas.lines.where((l) => l.$1.dx == l.$2.dx).toList();
      expect(verticals, hasLength(1));
      // Four horizontal grid lines and no more.
      expect(canvas.lines.where((l) => l.$1.dy == l.$2.dy), hasLength(4));
    });

    test('leaves an off-sample vertex unmarked when guides are off '
        '(the autofocus overlay rendering)', () {
      final canvas = _RecordingCanvas();
      _twoCurves(guides: false).paint(canvas, size);
      expect(canvas.lines.where((l) => l.$1.dx == l.$2.dx), isEmpty);
    });

    test('places the two vertices apart, in scan order', () {
      final canvas = _RecordingCanvas();
      _twoCurves().paint(canvas, size);
      final guide = canvas.lines.firstWhere((l) => l.$1.dx == l.$2.dx);
      // The ringed 6620 sample sits right of the 6515 guide: the backlash is
      // the gap, and a chart that collapsed it would hide the measurement.
      final ringIndex = canvas.circleRadii.indexOf(8.0);
      expect(canvas.circles[ringIndex].dx, greaterThan(guide.$1.dx));
    });

    test('paints nothing when no series has a point', () {
      final canvas = _RecordingCanvas();
      VCurvePainter(
        series: const [VCurveSeries(points: [], color: Colors.white)],
        gridColor: SkotiqColors.dark.border,
        textColor: SkotiqColors.dark.textMuted,
      ).paint(canvas, size);
      expect(canvas.paths, 0);
      expect(canvas.circles, isEmpty);
      expect(canvas.lines, isEmpty);
    });

    test('repaints when a scan gains a point or a vertex arrives', () {
      final one = _twoCurves();
      expect(one.shouldRepaint(_twoCurves()), isFalse);

      final grown = VCurvePainter(
        series: const [
          VCurveSeries(
            points: [..._belowPoints, VCurvePoint(position: 6800, hfr: 7)],
            color: SkotiqChartColors.seriesBlue,
            vertexPosition: 6620,
            showVertexGuide: true,
          ),
          VCurveSeries(
            points: _abovePoints,
            color: SkotiqChartColors.seriesAmber,
            vertexPosition: 6515,
            showVertexGuide: true,
          ),
        ],
        gridColor: SkotiqColors.dark.border,
        textColor: SkotiqColors.dark.textMuted,
        density: VCurveChartDensity.expanded,
      );
      expect(grown.shouldRepaint(one), isTrue);
    });
  });

  group('VCurveChart', () {
    testWidgets('describes both series to assistive technology', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 240,
              child: VCurveChart(
                gridColor: SkotiqColors.dark.border,
                textColor: SkotiqColors.dark.textMuted,
                series: const [
                  VCurveSeries(
                    points: _belowPoints,
                    color: SkotiqChartColors.seriesBlue,
                    label: 'From below',
                    vertexPosition: 6620,
                  ),
                  VCurveSeries(
                    points: _abovePoints,
                    color: SkotiqChartColors.seriesAmber,
                    label: 'From above',
                    vertexPosition: 6515,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final semantics = tester.getSemantics(find.byType(VCurveChart));
      expect(
        semantics.label,
        contains('From below: 5 points, optimum at 6620'),
      );
      expect(
        semantics.label,
        contains('From above: 5 points, optimum at 6515'),
      );
    });
  });
}
