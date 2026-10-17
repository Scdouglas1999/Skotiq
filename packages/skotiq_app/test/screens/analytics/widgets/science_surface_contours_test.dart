// The 3D Surface Explorer's "Contours" chip draws marching-squares iso-lines
// across the interpolated tile grid — iso-value lines inside the 3D projection,
// not stems to a flat baseline.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_surface_explorer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ScienceTileMetricRow _tile(int row, int col, double value) =>
    ScienceTileMetricRow(
      id: row * 5 + col,
      sessionId: 1,
      timestamp: DateTime.utc(2026, 8, 1),
      layerType: 'uniformity',
      tileRow: row,
      tileCol: col,
      sampleCount: 40,
      value: value,
      p05: 0,
      p50: value,
      p95: 1,
      auxValue: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isoContourSegments', () {
    test('a left-to-right ramp crosses each level once per grid row', () {
      // Values rise with the column only, so the 0.5 iso-line is the vertical
      // x = 2 line: one segment in each of the three cell rows.
      final grid = List<List<double?>>.generate(
        4,
        (_) => List<double?>.generate(5, (c) => c / 4),
      );
      final segments = isoContourSegments(grid, const [0.5]);

      expect(segments, hasLength(3));
      for (final s in segments) {
        expect(s.x0, closeTo(2.0, 1e-9));
        expect(s.x1, closeTo(2.0, 1e-9));
        expect(s.level, 0.5);
      }
    });

    test('a level outside the data draws nothing', () {
      final grid = List<List<double?>>.generate(
        3,
        (_) => List<double?>.generate(3, (c) => 0.1 * c),
      );
      expect(isoContourSegments(grid, const [0.9]), isEmpty);
    });

    test('cells with a missing tile are skipped, not guessed', () {
      final grid = List<List<double?>>.generate(
        2,
        (_) => List<double?>.generate(2, (c) => c.toDouble()),
      );
      expect(isoContourSegments(grid, const [0.5]), hasLength(1));
      grid[1][1] = null;
      expect(isoContourSegments(grid, const [0.5]), isEmpty);
    });
  });

  testWidgets('the Contours chip draws iso-lines, not stems to a baseline',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // A 5x5 dome: high in the middle, low at the edges, so every level has a
    // closed iso-line.
    final tiles = <ScienceTileMetricRow>[
      for (var r = 0; r < 5; r++)
        for (var c = 0; c < 5; c++)
          _tile(r, c, 1.0 - ((r - 2).abs() + (c - 2).abs()) / 4.0),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: ScienceSurfaceExplorer(
                colors: SkotiqColors.of(context),
                tiles: tiles,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final painter = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString().contains('Surface'),
    );
    expect(painter, findsOneWidget);

    // Contours off: markers only, no lines at all.
    expect(painter, isNot(paints..line()));

    await tester.tap(find.text('Contours'));
    await tester.pumpAndSettle();

    final lines = <(Offset, Offset)>[];
    expect(
      painter,
      paints
        ..everything((Symbol method, List<dynamic> arguments) {
          if (method == #drawLine) {
            lines.add((arguments[0] as Offset, arguments[1] as Offset));
          }
          return true;
        }),
    );

    // The painter must draw exactly the iso-line segments of this grid. A
    // lollipop stem per tile would be 25 segments, which no set of contour
    // levels over this dome produces.
    //
    // The painter normalises tile values against the 5th/95th percentile of
    // the layer: sorted, that is low = 0.0 and high = 0.75 here.
    final normalised = List<List<double?>>.generate(
      5,
      (r) => List<double?>.generate(
        5,
        (c) =>
            ((1.0 - ((r - 2).abs() + (c - 2).abs()) / 4.0) / 0.75).clamp(0, 1),
      ),
    );
    final expected = isoContourSegments(normalised, kSurfaceContourLevels);
    expect(expected.length, greaterThan(4),
        reason: 'a 5x5 dome should produce several iso-line segments');
    expect(expected.length, isNot(tiles.length));
    expect(lines, hasLength(expected.length));

    // No line may fall back to the flat baseline the stems shared: every
    // endpoint has to be a projected surface point, so no two lines may share
    // an identical y while differing in x at that end.
    final terminalYs = lines.map((l) => l.$2.dy).toSet();
    expect(terminalYs.length, greaterThan(1),
        reason: 'all lines ending at one y is a baseline, not a contour set');
  });
}
