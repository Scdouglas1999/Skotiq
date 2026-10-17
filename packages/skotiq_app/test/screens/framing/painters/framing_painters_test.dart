// Tests for the framing overlay painters after the C5 "kill triple-scale bug"
// migration: [FramingFOVPainter], [FramingEquipmentFOVOverlayPainter] and
// [FramingMosaicGridPainter] all derive their on-screen geometry from the *one*
// shared [FramingPlateScale], so a rectangle one degree wide is painted at the
// same number of pixels by every overlay (and by the survey background, whose
// draw rect uses the same plate scale).
//
// The painters take a [Canvas] and draw rounded/plain rects; to assert geometry
// without a GPU surface we record every rect drawn through a thin [Canvas]
// proxy and inspect the widths/heights.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/framing_painters.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A [Canvas] that forwards nothing to a real surface but records the bounding
/// [Rect] of every `drawRect` / `drawRRect` call so tests can assert the
/// painted geometry. All other canvas operations are no-ops, which is all the
/// painters under test require.
class _RecordingCanvas implements Canvas {
  /// Every `drawRect` bounding rect, in call order.
  final List<Rect> plainRects = <Rect>[];

  /// Every `drawRRect` outer rect, in call order.
  final List<Rect> roundedRects = <Rect>[];

  @override
  void drawRect(Rect rect, Paint paint) => plainRects.add(rect);

  @override
  void drawRRect(ui.RRect rrect, Paint paint) =>
      roundedRects.add(rrect.outerRect);

  @override
  void noSuchMethod(Invocation invocation) {}
}

const _canvas = Size(1000, 1000);

/// A square 2deg x 2deg survey registration: 800x800px image. With a square
/// canvas this yields pixelsPerDegree = 1000 / 2.0 = 500 at zoom 1.0.
const _plateScale = FramingPlateScale(
  surveyFovWidthDeg: 2.0,
  surveyFovHeightDeg: 2.0,
  imagePixelWidth: 800,
  imagePixelHeight: 800,
);

const _colors = SkotiqColors.dark;

/// A single panel at the mosaic origin, used for the 1x1 mosaic geometry tests.
const _singlePanel = <FramingMosaicPanel>[
  FramingMosaicPanel(
    index: 0,
    column: 0,
    row: 0,
    centerRaHours: 0.0,
    centerDecDegrees: 0.0,
    name: 'Panel 1 (0,0)',
  ),
];

/// The FOV rectangle drawn by [FramingFOVPainter] /
/// [FramingEquipmentFOVOverlayPainter] is the first rounded-rect they draw
/// (fill then border share it).
Rect _firstRoundedRect(_RecordingCanvas canvas) => canvas.roundedRects.first;

/// The mosaic outline / panel rectangles are plain rects; for a 1x1, 0%-overlap
/// mosaic the first plain rect (the outline) has the single panel's dimensions.
Rect _firstPlainRect(_RecordingCanvas canvas) => canvas.plainRects.first;

void main() {
  group('shared plate scale co-registration (triple-scale bug fix)', () {
    const fovWidth = 1.5;
    const fovHeight = 1.0;
    const zoom = 1.0;

    final expectedPxPerDeg = _plateScale.pixelsPerDegree(_canvas, zoom);
    final expectedRectWidth = fovWidth * expectedPxPerDeg;
    final expectedRectHeight = fovHeight * expectedPxPerDeg;

    test('FramingFOVPainter sizes the FOV rect from the shared plate scale',
        () {
      final canvas = _RecordingCanvas();
      FramingFOVPainter(
        fovWidth: fovWidth,
        fovHeight: fovHeight,
        zoom: zoom,
        plateScale: _plateScale,
        colors: _colors,
        showDirections: false,
      ).paint(canvas, _canvas);

      final fovRect = _firstRoundedRect(canvas);
      expect(fovRect.width, closeTo(expectedRectWidth, 1e-6));
      expect(fovRect.height, closeTo(expectedRectHeight, 1e-6));
    });

    test(
        'FramingEquipmentFOVOverlayPainter sizes the FOV rect from the shared '
        'plate scale (no longer size.width/previewFov)', () {
      final canvas = _RecordingCanvas();
      FramingEquipmentFOVOverlayPainter(
        fovWidth: fovWidth,
        fovHeight: fovHeight,
        zoom: zoom,
        plateScale: _plateScale,
        colors: _colors,
        opacity: 0.5,
        showDirections: false,
      ).paint(canvas, _canvas);

      final fovRect = _firstRoundedRect(canvas);
      expect(fovRect.width, closeTo(expectedRectWidth, 1e-6));
      expect(fovRect.height, closeTo(expectedRectHeight, 1e-6));
    });

    test(
        'FramingMosaicGridPainter sizes a 1x1 panel from the shared plate scale',
        () {
      final canvas = _RecordingCanvas();
      const config = FramingMosaicConfig(
        rows: 1,
        columns: 1,
        overlapPercent: 0,
      );

      FramingMosaicGridPainter(
        config: config,
        panels: _singlePanel,
        fovWidth: fovWidth,
        fovHeight: fovHeight,
        zoom: zoom,
        plateScale: _plateScale,
        colors: _colors,
        showPanelNumbers: false,
        showSequencePath: false,
        selectedPanelIndex: -1,
      ).paint(canvas, _canvas);

      // For a 1x1, 0% overlap mosaic the outline rect (first plain rect drawn)
      // has the single panel's dimensions; assert it matches the shared scale.
      final panelRect = _firstPlainRect(canvas);
      expect(panelRect.width, closeTo(expectedRectWidth, 1e-6));
      expect(panelRect.height, closeTo(expectedRectHeight, 1e-6));
    });

    test('all three painters agree on the FOV rect size to the pixel', () {
      Rect roundedRectOf(CustomPainter painter) {
        final canvas = _RecordingCanvas();
        painter.paint(canvas, _canvas);
        return _firstRoundedRect(canvas);
      }

      final fov = roundedRectOf(FramingFOVPainter(
        fovWidth: fovWidth,
        fovHeight: fovHeight,
        zoom: zoom,
        plateScale: _plateScale,
        colors: _colors,
        showDirections: false,
      ));
      final equip = roundedRectOf(FramingEquipmentFOVOverlayPainter(
        fovWidth: fovWidth,
        fovHeight: fovHeight,
        zoom: zoom,
        plateScale: _plateScale,
        colors: _colors,
        opacity: 0.5,
        showDirections: false,
      ));
      const config =
          FramingMosaicConfig(rows: 1, columns: 1, overlapPercent: 0);
      final mosaicCanvas = _RecordingCanvas();
      FramingMosaicGridPainter(
        config: config,
        panels: _singlePanel,
        fovWidth: fovWidth,
        fovHeight: fovHeight,
        zoom: zoom,
        plateScale: _plateScale,
        colors: _colors,
        showPanelNumbers: false,
        showSequencePath: false,
        selectedPanelIndex: -1,
      ).paint(mosaicCanvas, _canvas);
      final mosaic = _firstPlainRect(mosaicCanvas);

      expect(fov.width, closeTo(equip.width, 1e-6));
      expect(fov.width, closeTo(mosaic.width, 1e-6));
      expect(fov.height, closeTo(equip.height, 1e-6));
      expect(fov.height, closeTo(mosaic.height, 1e-6));
    });

    test('FOV rect scales linearly with zoom via the shared plate scale', () {
      Rect fovRectAtZoom(double z) {
        final canvas = _RecordingCanvas();
        FramingFOVPainter(
          fovWidth: fovWidth,
          fovHeight: fovHeight,
          zoom: z,
          plateScale: _plateScale,
          colors: _colors,
          showDirections: false,
        ).paint(canvas, _canvas);
        return _firstRoundedRect(canvas);
      }

      final atOne = fovRectAtZoom(1.0);
      final atTwo = fovRectAtZoom(2.0);
      expect(atTwo.width, closeTo(atOne.width * 2.0, 1e-6));
      expect(atTwo.height, closeTo(atOne.height * 2.0, 1e-6));
    });
  });

  group('rotation handle geometry constants (C6 contract)', () {
    test('exposes documented handle gap / radius / hit tolerance', () {
      // These are the single source of truth the C6 gesture ring imports so the
      // hit geometry matches where the handle is painted. They must stay
      // positive and finite; a senior reviewer should be able to read the
      // contract here rather than discover magic numbers in the gesture code.
      expect(FramingFOVPainter.rotationHandleGap, greaterThan(0));
      expect(FramingFOVPainter.rotationHandleRadius, greaterThan(0));
      expect(FramingFOVPainter.rotationHitTolerance, greaterThan(0));
    });
  });

  group('shouldRepaint reacts to plate scale changes', () {
    FramingFOVPainter fov(FramingPlateScale scale) => FramingFOVPainter(
          fovWidth: 1.0,
          fovHeight: 1.0,
          zoom: 1.0,
          plateScale: scale,
          colors: _colors,
          showDirections: false,
        );

    test('FramingFOVPainter repaints when the plate scale changes', () {
      final a = fov(_plateScale);
      final b = fov(_plateScale.copyWith(surveyFovWidthDeg: 3.0));
      expect(a.shouldRepaint(b), isTrue);
    });

    test('FramingFOVPainter does not repaint for an identical plate scale', () {
      final a = fov(_plateScale);
      final b = fov(_plateScale.copyWith());
      expect(a.shouldRepaint(b), isFalse);
    });
  });
}
