// The FWHM/uniformity surface explorer encoded its measurement in raw hue: the
// surface markers and iso-contours ramped #1D4ED8 to #DC2626, and the scale bar
// that explains them repeated the same two constants as a literal gradient. Red
// night is a WAVELENGTH constraint, so the blue half of that ramp — and the
// blue half of the key beside it — undid the dark adaptation the mode exists to
// protect. Both now name the endpoints and resolve them through
// `SkotiqChartColors.forTheme`, the surface once per painter and the bar
// once per build.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_surface_explorer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Captures the colour of every mark the surface painter makes.
class _RecordingCanvas implements Canvas {
  final List<Color> painted = [];

  void _record(Paint paint) => painted.add(paint.color);

  @override
  void drawRect(Rect rect, Paint paint) => _record(paint);

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => _record(paint);

  @override
  void drawCircle(Offset c, double radius, Paint paint) => _record(paint);

  @override
  void drawPath(Path path, Paint paint) => _record(paint);

  @override
  void drawRRect(RRect rrect, Paint paint) => _record(paint);

  @override
  void drawOval(Rect rect, Paint paint) => _record(paint);

  @override
  int getSaveCount() => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Fraction of the emitted channel energy carried by red.
double _redShare(Color c) {
  final total = c.r + c.g + c.b;
  return total == 0 ? 1.0 : c.r / total;
}

/// Greys carry no hue to remap; the plot's axes and baseline are drawn from
/// theme text/border tokens, which are already theme-correct.
bool _isAchromatic(Color c) => c.r == c.g && c.g == c.b;

/// `Paint.color` round-trips through float32, so an exact `==` on the channels
/// never fires and would make this check pass on raw code.
bool _sameHue(Color a, Color b) =>
    (a.r - b.r).abs() < 1e-3 &&
    (a.g - b.g).abs() < 1e-3 &&
    (a.b - b.b).abs() < 1e-3;

/// A 4x4 uniformity field with a real gradient across it, so the surface has
/// both ramp ends to draw.
List<ScienceTileMetricRow> _tiles() => [
      for (var r = 0; r < 4; r++)
        for (var c = 0; c < 4; c++)
          ScienceTileMetricRow(
            id: r * 4 + c + 1,
            timestamp: DateTime.utc(2026, 8, 1),
            layerType: ScienceLayerType.uniformity.dbValue,
            tileRow: r,
            tileCol: c,
            sampleCount: 200,
            value: (r * 4 + c) / 15.0,
            p05: 0,
            p50: 0.5,
            p95: 1,
            auxValue: 0,
          ),
    ];

Future<void> _pump(WidgetTester tester, SkotiqColors colors) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: colors.isRedNight ? SkotiqTheme.redNight : SkotiqTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ScienceSurfaceExplorer(colors: colors, tiles: _tiles()),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Replay every painter under the explorer onto a recording canvas.
List<Color> _surfaceMarks(WidgetTester tester) {
  final canvas = _RecordingCanvas();
  for (final paint
      in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    paint.painter?.paint(canvas, const Size(480, 320));
  }
  return canvas.painted;
}

/// Every gradient the explorer hands to a [BoxDecoration] — the scale bar key.
List<Color> _gradientStops(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.decoration)
    .whereType<BoxDecoration>()
    .map((d) => d.gradient)
    .whereType<LinearGradient>()
    .expand((g) => g.colors)
    .toList(growable: false);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 2200);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('red night paints no blue surface marker', (tester) async {
    await _pump(tester, SkotiqColors.redNight);

    final marks = _surfaceMarks(tester)
        .where((c) => c.a > 0 && !_isAchromatic(c))
        .toList(growable: false);
    expect(marks, isNotEmpty,
        reason: 'the surface drew no coloured marks — the test proves nothing');
    for (final c in marks) {
      expect(c.b, lessThanOrEqualTo(c.r),
          reason: 'the surface painted $c, which emits more blue than red');
      expect(c.g, lessThanOrEqualTo(c.r),
          reason: 'the surface painted $c, which emits more green than red');
      expect(_redShare(c), greaterThan(0.5),
          reason: 'the surface painted $c, which does not keep red dominant');
    }
    for (final named in [namedSurfaceLowValue, namedSurfaceHighValue]) {
      expect(marks.where((c) => _sameHue(c, named)), isEmpty,
          reason: 'the surface still paints $named raw');
    }
  });

  testWidgets('red night remaps the scale-bar key with the surface',
      (tester) async {
    await _pump(tester, SkotiqColors.redNight);

    final stops = _gradientStops(tester);
    expect(
      stops,
      containsAll([
        SkotiqChartColors.forTheme(namedSurfaceLowValue, SkotiqColors.redNight),
        SkotiqChartColors.forTheme(
            namedSurfaceHighValue, SkotiqColors.redNight),
      ]),
      reason: 'the scale bar does not route its ramp through forTheme',
    );
    expect(stops, isNot(contains(namedSurfaceLowValue)));
    expect(stops, isNot(contains(namedSurfaceHighValue)));
  });

  testWidgets('dark keeps the named ramp exactly', (tester) async {
    await _pump(tester, SkotiqColors.dark);

    expect(
      _gradientStops(tester),
      containsAll([namedSurfaceLowValue, namedSurfaceHighValue]),
      reason: 'the remap must be the identity outside red night',
    );
  });
}
