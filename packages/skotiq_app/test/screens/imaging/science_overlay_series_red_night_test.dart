// Every science overlay drawn over the preview encoded its measurement in raw
// HUE: the PSF heatmap ramped #0B6E4F to #C0392B, the uniformity map #0B3D91 to
// #FF8C42, the clip map #3B82F6 to #EF4444, the residual field #F1C40F, the
// moving-track confidence ramp #F59E0B to #22C55E, and the compass drew its
// East arrow in #44AAFF. Red night is a WAVELENGTH constraint, so those are not
// merely off-palette — a green heatmap and a blue compass arrow undo the dark
// adaptation the mode exists to protect.
//
// The fix routes every ramp endpoint through `SkotiqChartColors.forTheme`
// ONCE, at painter construction, and interpolates between the RESOLVED
// endpoints. Both halves matter and both are asserted below: the seam (the
// painter's endpoints came from the remap) and the draw (nothing chromatic
// reaches the canvas that is not red-dominant). Lerping the named hues first
// and resolving after would satisfy the first and fail the second.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/overlay_painters.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Captures the colour of every mark a painter puts on the canvas.
///
/// A real [ui.Canvas] keeps no record of the paints it was handed, and a golden
/// would answer "did the pixels change", not "is this colour red-dominant".
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

const Size _canvasSize = Size(800, 600);

/// Fraction of the emitted channel energy carried by red.
double _redShare(Color c) {
  final total = c.r + c.g + c.b;
  return total == 0 ? 1.0 : c.r / total;
}

/// True for greys, black and white: no hue to remap, so an achromatic mark is
/// not a series colour. The tile grid lines and the compass rose's backing
/// disc, border and label shadows are all achromatic by design — they are
/// legibility chrome over an arbitrary image, not an encoded measurement.
bool _isAchromatic(Color c) => c.r == c.g && c.g == c.b;

void _expectEveryHueIsRed(_RecordingCanvas canvas, String what) {
  final chromatic = canvas.painted
      .where((c) => c.a > 0 && !_isAchromatic(c))
      .toList(growable: false);
  expect(chromatic, isNotEmpty,
      reason: '$what drew no coloured marks — the test proves nothing');
  for (final c in chromatic) {
    expect(c.g, lessThanOrEqualTo(c.r),
        reason: '$what painted $c, which emits more green than red');
    expect(c.b, lessThanOrEqualTo(c.r),
        reason: '$what painted $c, which emits more blue than red');
    expect(_redShare(c), greaterThan(0.5),
        reason: '$what painted $c, which does not keep red dominant');
  }
}

/// The named hue itself must never reach the canvas.
///
/// Red-dominance alone is too weak a net at the warm end of the palette: the
/// residual field's raw #F1C40F yellow already emits 53% red and slips straight
/// through it. Matching the RGB triple catches those — alpha varies per mark,
/// so it is excluded.
///
/// The comparison is epsilon-based, not exact. `Paint.color` round-trips its
/// channels through float32, so a colour that came off a const `Color` arrives
/// here a few ulps off and an `==` on the channels never fires — a check that
/// looks like this one but uses exact equality passes on RAW code and proves
/// nothing.
bool _sameHue(Color a, Color b) =>
    (a.r - b.r).abs() < 1e-3 &&
    (a.g - b.g).abs() < 1e-3 &&
    (a.b - b.b).abs() < 1e-3;

void _expectNoNamedHuePainted(
  _RecordingCanvas canvas,
  Map<String, Color> named,
  String what,
) {
  for (final entry in named.entries) {
    final leaked = canvas.painted
        .where((c) => _sameHue(c, entry.value))
        .toList(growable: false);
    expect(leaked, isEmpty,
        reason: '$what still paints its ${entry.key} hue raw');
  }
}

Color _redNight(Color named) =>
    SkotiqChartColors.forTheme(named, SkotiqColors.redNight);

PsfFieldTileRow _psfTile(int row, int col,
        {required double fwhm, int stars = 40}) =>
    PsfFieldTileRow(
      id: row * 10 + col,
      tileRow: row,
      tileCol: col,
      starCount: stars,
      medianFwhm: fwhm,
      medianHfr: fwhm / 2,
      medianEccentricity: 0.2,
      roundness: 0.9,
      timestamp: DateTime.utc(2026, 8, 1),
    );

ScienceTileMetricRow _metricTile(
  int row,
  int col, {
  required double value,
  required String layer,
}) =>
    ScienceTileMetricRow(
      id: row * 10 + col,
      timestamp: DateTime.utc(2026, 8, 1),
      layerType: layer,
      tileRow: row,
      tileCol: col,
      sampleCount: 100,
      value: value,
      p05: 0,
      p50: value,
      p95: 1,
      auxValue: 0,
    );

/// A 3x3 field spanning the full metric range, so both ramp endpoints and the
/// midpoints between them are actually drawn.
List<PsfFieldTileRow> _psfField() => [
      for (var r = 0; r < 3; r++)
        for (var c = 0; c < 3; c++)
          _psfTile(r, c,
              fwhm: 2.0 + (r * 3 + c) * 0.5, stars: r == 2 && c == 2 ? 0 : 40),
    ];

List<ScienceTileMetricRow> _metricField(String layer) => [
      for (var r = 0; r < 3; r++)
        for (var c = 0; c < 3; c++)
          _metricTile(r, c, value: (r * 3 + c) / 8.0, layer: layer),
    ];

void main() {
  group('PSF heatmap', () {
    SciencePsfOverlayPainter painter(SkotiqColors colors) =>
        SciencePsfOverlayPainter(
          tiles: _psfField(),
          imageOffset: Offset.zero,
          zoomLevel: 1,
          imageWidth: 600,
          imageHeight: 400,
          colors: colors,
        );

    test('red night resolves the ramp through forTheme', () {
      final p = painter(SkotiqColors.redNight);
      expect(p.tightColor, _redNight(namedPsfTight));
      expect(p.bloatedColor, _redNight(namedPsfBloated));
      expect(p.noStarsColor, _redNight(namedPsfNoStars));
      expect(p.tightColor, isNot(namedPsfTight));
    });

    test('red night paints no green tile', () {
      final canvas = _RecordingCanvas();
      painter(SkotiqColors.redNight).paint(canvas, _canvasSize);
      _expectEveryHueIsRed(canvas, 'the PSF heatmap');
      _expectNoNamedHuePainted(
          canvas,
          {
            'tight': namedPsfTight,
            'bloated': namedPsfBloated,
            'no-stars': namedPsfNoStars,
          },
          'the PSF heatmap');
    });

    test('dark keeps the named ramp exactly', () {
      final p = painter(SkotiqColors.dark);
      expect(p.tightColor, namedPsfTight);
      expect(p.bloatedColor, namedPsfBloated);
      expect(p.noStarsColor, namedPsfNoStars);
    });
  });

  group('uniformity map', () {
    ScienceUniformityOverlayPainter painter(SkotiqColors colors) =>
        ScienceUniformityOverlayPainter(
          tiles: _metricField('uniformity'),
          imageOffset: Offset.zero,
          zoomLevel: 1,
          imageWidth: 600,
          imageHeight: 400,
          opacity: 0.5,
          colors: colors,
        );

    test('red night resolves the ramp through forTheme', () {
      final p = painter(SkotiqColors.redNight);
      expect(p.flatColor, _redNight(namedUniformityFlat));
      expect(p.strongColor, _redNight(namedUniformityStrong));
      expect(p.flatColor, isNot(namedUniformityFlat));
    });

    test('red night paints no navy tile', () {
      final canvas = _RecordingCanvas();
      painter(SkotiqColors.redNight).paint(canvas, _canvasSize);
      _expectEveryHueIsRed(canvas, 'the uniformity map');
      _expectNoNamedHuePainted(
          canvas,
          {
            'flat': namedUniformityFlat,
            'strong': namedUniformityStrong,
          },
          'the uniformity map');
    });

    test('dark keeps the named ramp exactly', () {
      final p = painter(SkotiqColors.dark);
      expect(p.flatColor, namedUniformityFlat);
      expect(p.strongColor, namedUniformityStrong);
    });
  });

  group('clip map', () {
    ScienceClipOverlayPainter painter(SkotiqColors colors) =>
        ScienceClipOverlayPainter(
          highTiles: _metricField('clip_high'),
          lowTiles: _metricField('clip_low'),
          imageOffset: Offset.zero,
          zoomLevel: 1,
          imageWidth: 600,
          imageHeight: 400,
          opacity: 0.5,
          colors: colors,
        );

    test('red night resolves the ramp through forTheme', () {
      final p = painter(SkotiqColors.redNight);
      expect(p.lowClipColor, _redNight(namedClipLow));
      expect(p.highClipColor, _redNight(namedClipHigh));
      expect(p.lowClipColor, isNot(namedClipLow));
    });

    test('red night paints no blue tile', () {
      final canvas = _RecordingCanvas();
      painter(SkotiqColors.redNight).paint(canvas, _canvasSize);
      _expectEveryHueIsRed(canvas, 'the clip map');
      _expectNoNamedHuePainted(
          canvas,
          {
            'low-clip': namedClipLow,
            'high-clip': namedClipHigh,
          },
          'the clip map');
    });

    test('dark keeps the named ramp exactly', () {
      final p = painter(SkotiqColors.dark);
      expect(p.lowClipColor, namedClipLow);
      expect(p.highClipColor, namedClipHigh);
    });
  });

  group('residual vector field', () {
    ScienceResidualOverlayPainter painter(SkotiqColors colors) =>
        ScienceResidualOverlayPainter(
          vectors: List.generate(
            12,
            (i) => AstrometryResidualVectorRow(
              id: i + 1,
              x: 40.0 + i * 30,
              y: 40.0 + i * 20,
              dxArcsec: 0.4,
              dyArcsec: -0.3,
              magnitudeArcsec: 0.5,
              timestamp: DateTime.utc(2026, 8, 1),
            ),
          ),
          imageOffset: Offset.zero,
          zoomLevel: 1,
          colors: colors,
        );

    test('red night resolves both vector hues through forTheme', () {
      final p = painter(SkotiqColors.redNight);
      expect(p.shaftColor, _redNight(namedResidualShaft));
      expect(p.headColor, _redNight(namedResidualHead));
      expect(p.shaftColor, isNot(namedResidualShaft));
    });

    test('red night paints no yellow vector', () {
      final canvas = _RecordingCanvas();
      painter(SkotiqColors.redNight).paint(canvas, _canvasSize);
      _expectEveryHueIsRed(canvas, 'the residual field');
      _expectNoNamedHuePainted(
          canvas,
          {
            'shaft': namedResidualShaft,
            'head': namedResidualHead,
          },
          'the residual field');
    });

    test('dark keeps the named hues exactly', () {
      final p = painter(SkotiqColors.dark);
      expect(p.shaftColor, namedResidualShaft);
      expect(p.headColor, namedResidualHead);
    });
  });

  group('moving-object tracks', () {
    ScienceMovingTrackOverlayPainter painter(SkotiqColors colors) =>
        ScienceMovingTrackOverlayPainter(
          tracks: List.generate(
            5,
            (i) => ProjectedMovingTrack(
              imageX: 60.0 + i * 90,
              imageY: 80.0 + i * 60,
              positionAngleDegrees: 30.0 * i,
              motionArcsecPerMinute: 4.0,
              confidence: i / 4.0,
            ),
          ),
          imageOffset: Offset.zero,
          zoomLevel: 1,
          colors: colors,
        );

    test('red night resolves the confidence ramp through forTheme', () {
      final p = painter(SkotiqColors.redNight);
      expect(p.lowConfidenceColor, _redNight(namedTrackLowConfidence));
      expect(p.highConfidenceColor, _redNight(namedTrackHighConfidence));
      expect(p.highConfidenceColor, isNot(namedTrackHighConfidence));
    });

    test('red night paints no green track', () {
      final canvas = _RecordingCanvas();
      painter(SkotiqColors.redNight).paint(canvas, _canvasSize);
      _expectEveryHueIsRed(canvas, 'the moving-track overlay');
      _expectNoNamedHuePainted(
          canvas,
          {
            'low-confidence': namedTrackLowConfidence,
            'high-confidence': namedTrackHighConfidence,
          },
          'the moving-track overlay');
    });

    test('dark keeps the named ramp exactly', () {
      final p = painter(SkotiqColors.dark);
      expect(p.lowConfidenceColor, namedTrackLowConfidence);
      expect(p.highConfidenceColor, namedTrackHighConfidence);
    });
  });

  group('compass rose', () {
    CompassOverlayPainter painter(SkotiqColors colors) =>
        CompassOverlayPainter(rotationDegrees: 12, colors: colors);

    test('red night resolves both axis hues through forTheme', () {
      final p = painter(SkotiqColors.redNight);
      expect(p.northColor, _redNight(namedCompassNorth));
      expect(p.eastColor, _redNight(namedCompassEast));
      expect(p.eastColor, isNot(namedCompassEast));
    });

    test('red night paints no blue East arrow', () {
      final canvas = _RecordingCanvas();
      painter(SkotiqColors.redNight).paint(canvas, _canvasSize);
      _expectEveryHueIsRed(canvas, 'the compass rose');
      _expectNoNamedHuePainted(
          canvas,
          {
            'north': namedCompassNorth,
            'east': namedCompassEast,
          },
          'the compass rose');
    });

    test('dark keeps the named axis hues exactly', () {
      final p = painter(SkotiqColors.dark);
      expect(p.northColor, namedCompassNorth);
      expect(p.eastColor, namedCompassEast);
    });
  });
}
