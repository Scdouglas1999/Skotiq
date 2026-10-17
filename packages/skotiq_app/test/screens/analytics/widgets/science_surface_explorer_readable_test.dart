// A field map has to say WHERE on the sensor and HOW BAD.
//
// Observed: with a 5x5 uniformity grid seeded the card drew 25 coloured dots on
// an otherwise empty panel — no axes, no colour bar, no min/max, no units, no
// hover or tap readout. A 2% uniformity spread and a 40% one drew the same
// picture, and a red corner could not be mapped onto a physical adjustment.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_surface_explorer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Captures where the painter lays text down. The corner tags are drawn ON the
/// surface by the painter, so nothing in the widget tree can see them.
class _TextRecordingCanvas implements Canvas {
  final List<Offset> textAt = [];

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) =>
      textAt.add(offset);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ScienceTileMetricRow _tile(int row, int col, double value) =>
    ScienceTileMetricRow(
      id: row * 10 + col,
      capturedImageId: 1,
      sessionId: 1,
      layerType: 'uniformity',
      tileRow: row,
      tileCol: col,
      value: value,
      p05: value,
      p50: value,
      p95: value,
      auxValue: 0,
      sampleCount: 4096,
      timestamp: DateTime.utc(2026, 8, 1),
    );

/// The finding's grid: 0.10 at (0,0) rising to 0.32 at (4,4).
List<ScienceTileMetricRow> _grid() => [
      for (var r = 0; r < 5; r++)
        for (var c = 0; c < 5; c++) _tile(r, c, 0.10 + (r + c) * 0.0275),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('surfaceValueScale', () {
    test('reports the ramp ends and the real extent separately', () {
      final scale = surfaceValueScale(_grid());
      expect(scale.min, closeTo(0.10, 1e-9));
      expect(scale.max, closeTo(0.32, 1e-9));
      expect(scale.median, greaterThan(scale.min));
      expect(scale.median, lessThan(scale.max));
      // The ramp saturates inside the extent, which is why both are shown.
      expect(scale.low, greaterThanOrEqualTo(scale.min));
      expect(scale.high, lessThanOrEqualTo(scale.max));
    });

    test('an empty layer does not divide by zero', () {
      final scale = surfaceValueScale(const []);
      expect(scale.max, 0.0);
    });
  });

  test('projectSurfaceTiles places every tile and normalises its height', () {
    final points = projectSurfaceTiles(
      tiles: _grid(),
      size: const Size(400, 240),
      yaw: -0.55,
      pitch: 0.75,
      zExaggeration: 1.6,
      low: 0.10,
      high: 0.32,
    );
    expect(points, hasLength(25));
    expect(points.every((p) => p.at.dx.isFinite && p.at.dy.isFinite), isTrue);
    final corner = points.firstWhere(
      (p) => p.tile.tileRow == 0 && p.tile.tileCol == 0,
    );
    expect(corner.norm, closeTo(0.0, 1e-6));
    final far = points.firstWhere(
      (p) => p.tile.tileRow == 4 && p.tile.tileCol == 4,
    );
    expect(far.norm, closeTo(1.0, 1e-6));
  });

  testWidgets('the card prints a value scale beside the colour ramp',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: ScienceSurfaceExplorer(
                colors: SkotiqColors.of(context),
                tiles: _grid(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('median'),
      findsOneWidget,
      reason: 'without numbers the map cannot be acted on',
    );
    expect(find.textContaining('range 0.100–0.320'), findsOneWidget);
    expect(
      find.textContaining('Tap a marker'),
      findsOneWidget,
      reason: 'the readout has to advertise itself',
    );
  });

  testWidgets('tapping a marker names its tile and value', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: ScienceSurfaceExplorer(
                colors: SkotiqColors.of(context),
                tiles: _grid(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final plot = tester.getRect(find.byKey(kScienceSurfacePlotKey));
    final points = projectSurfaceTiles(
      tiles: _grid(),
      size: plot.size,
      yaw: -0.55,
      pitch: 0.75,
      zExaggeration: 1.6,
      low: surfaceValueScale(_grid()).low,
      high: surfaceValueScale(_grid()).high,
    );
    final target = points.firstWhere(
      (p) => p.tile.tileRow == 4 && p.tile.tileCol == 4,
    );

    await tester.tapAt(plot.topLeft + target.at);
    await tester.pump();

    expect(find.textContaining('Tile r4·c4'), findsOneWidget);
    expect(find.textContaining('0.320'), findsWidgets);
  });

  // The corner tags are the half that says WHERE: without them a red blob
  // cannot be turned into a tilt adjustment. They are painted onto the surface,
  // so no finder can see them — the painter has to be driven directly.
  testWidgets('the painter tags all four grid corners on the surface',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: ScienceSurfaceExplorer(
                colors: SkotiqColors.of(context),
                tiles: _grid(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final plot = tester.getRect(find.byKey(kScienceSurfacePlotKey));
    final painter =
        tester.widget<CustomPaint>(find.byKey(kScienceSurfacePlotKey)).painter!;
    final canvas = _TextRecordingCanvas();
    painter.paint(canvas, plot.size);

    expect(
      canvas.textAt,
      hasLength(4),
      reason: 'one tag per grid corner — r0·c0, r0·c4, r4·c0, r4·c4',
    );

    // Each tag sits on the corner it names, wherever the surface is orbited to.
    final scale = surfaceValueScale(_grid());
    final projected = projectSurfaceTiles(
      tiles: _grid(),
      size: plot.size,
      yaw: -0.55,
      pitch: 0.75,
      zExaggeration: 1.6,
      low: scale.low,
      high: scale.high,
    );
    for (final corner in const [(0, 0), (0, 4), (4, 0), (4, 4)]) {
      final at = projected
          .firstWhere(
            (p) => p.tile.tileRow == corner.$1 && p.tile.tileCol == corner.$2,
          )
          .at;
      expect(
        canvas.textAt.any((o) => (o - at).distance < 40),
        isTrue,
        reason: 'no tag near the projected corner r${corner.$1}·c${corner.$2}',
      );
    }
  });
}
