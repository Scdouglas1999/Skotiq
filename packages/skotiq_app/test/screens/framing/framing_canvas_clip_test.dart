// Regression guard: the framing canvas must hard-clip its content to its bounded
// box at every zoom, so the survey-snapshot background (and any layer) never
// spills past the canvas edge and paints behind the framing sidebar.
//
// THE BUG THIS GUARDS: [FramingSurveyImagePainter] draws the survey cutout into
// [FramingPlateScale.drawRectFor], which at zoom > 1 is LARGER than the canvas;
// `Canvas.drawImageRect` does not clip to the CustomPaint's RenderBox, so without
// a clip the background bled to the right, behind the "Target" side panel. The
// HiPS tile painter self-clips (so only the background bled). [FramingCanvas] now
// wraps its content in a [ClipRect]; these tests pin that the clip exists and that
// a high-zoom survey background truly does not paint outside the canvas region.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/framing_background_painters.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A fully-saturated red survey image, so any pixel of it that escapes the canvas
/// is trivially detectable against a black surround (no other layer is red).
Future<ui.Image> _redSurveyImage(int w, int h) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFFF0000),
  );
  return recorder.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image surveyImage;
  setUpAll(() async {
    // A 4:3 cutout; its content is irrelevant beyond being detectably red.
    surveyImage = await _redSurveyImage(800, 600);
  });
  tearDownAll(() => surveyImage.dispose());

  /// Pumps the canvas inside a fixed-size box that is itself surrounded by a
  /// black region (standing in for the sidebar / chrome). [canvasSide] is the
  /// canvas box; the total surface is larger so a bleed lands on black.
  testWidgets('FramingCanvas wraps its content in a ClipRect', (tester) async {
    // A canvas wide enough for the on-canvas controls Row (survey dropdown +
    // chips) not to overflow — that Row is unrelated chrome and a too-narrow box
    // would throw a layout overflow rather than test the clip.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      // Keep the HiPS layer inert so this isolates the survey-background canvas.
      hipsFramingEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 700,
                height: 500,
                child: FramingCanvas(
                  colors: SkotiqColors.dark,
                  framingState: FramingState(
                    surveyImage: surveyImage,
                    plateScale: const FramingPlateScale(
                      surveyFovWidthDeg: 2.0,
                      surveyFovHeightDeg: 1.5,
                      imagePixelWidth: 800,
                      imagePixelHeight: 600,
                    ),
                    zoom: 1.0,
                  ),
                  equipmentResult: null,
                  onPan: (_, __, ___) {},
                  onRotate: (_) {},
                  onAimChanged: (_, __) {},
                  onCanvasResized: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The clip must be a descendant of the FramingCanvas subtree.
    final clip = find.descendant(
      of: find.byType(FramingCanvas),
      matching: find.byType(ClipRect),
    );
    expect(clip, findsWidgets,
        reason: 'FramingCanvas must clip its content to the canvas bounds so '
            'nothing paints behind the sidebar.');
  });

  // Painter-level containment check across zooms: it rasterises the REAL
  // [FramingSurveyImagePainter] onto a surface LARGER than the canvas, both
  // without a clip and inside a `clipRect(canvasBounds)` (exactly the clip the
  // canvas [ClipRect] installs). At each zoom it asserts the clip is what keeps
  // the survey background inside the canvas: the unclipped render MUST bleed at
  // zoom > 1 (proving the draw rect overruns the canvas), and the clipped render
  // must NOT bleed at any zoom (proving the clip contains it). This is a pure
  // `dart:ui` rasterisation, so it is fast and deterministic (no slow
  // widget-tree GPU capture).
  test(
      'survey background is contained by a canvas clip at every zoom '
      '(0.5x, 1x, 2x, 4x); unclipped it bleeds past the canvas at zoom > 1',
      () async {
    const canvasW = 400, canvasH = 300; // the bounded canvas box
    const surfaceW = 700, surfaceH = 500; // larger, to reveal any bleed
    const plate = FramingPlateScale(
      surveyFovWidthDeg: 2.0,
      surveyFovHeightDeg: 1.5,
      imagePixelWidth: 800,
      imagePixelHeight: 600,
    );

    Future<int> bleedPixels({required double zoom, required bool clip}) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      // Black surround.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, surfaceW.toDouble(), surfaceH.toDouble()),
        Paint()..color = const Color(0xFF000000),
      );
      if (clip) {
        // Exactly what the canvas ClipRect installs: clip to the canvas box.
        canvas.clipRect(
            Rect.fromLTWH(0, 0, canvasW.toDouble(), canvasH.toDouble()));
      }
      // The real survey painter, sized to the CANVAS box (its `size` arg is the
      // canvas, like the CustomPaint(Positioned.fill) in FramingCanvas).
      FramingSurveyImagePainter(
        image: surveyImage,
        zoom: zoom,
        panX: 0,
        panY: 0,
        rotation: 0,
        plateScale: plate,
      ).paint(canvas, Size(canvasW.toDouble(), canvasH.toDouble()));

      final img = await recorder.endRecording().toImage(surfaceW, surfaceH);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      img.dispose();

      // Count survey-red pixels in the surround strips (right of / below canvas).
      const m = 2;
      var bleed = 0;
      bool red(int x, int y) {
        final i = (y * surfaceW + x) * 4;
        return bytes[i] > 180 && bytes[i + 1] < 80 && bytes[i + 2] < 80;
      }

      for (var y = 0; y < surfaceH; y++) {
        for (var x = canvasW + m; x < surfaceW; x++) {
          if (red(x, y)) bleed++;
        }
      }
      for (var y = canvasH + m; y < surfaceH; y++) {
        for (var x = 0; x < canvasW; x++) {
          if (red(x, y)) bleed++;
        }
      }
      return bleed;
    }

    for (final zoom in const [0.5, 1.0, 2.0, 4.0]) {
      final clipped = await bleedPixels(zoom: zoom, clip: true);
      expect(clipped, 0,
          reason:
              'At zoom $zoom the clipped survey background bled $clipped px '
              'past the ${canvasW}x$canvasH canvas — the ClipRect must contain '
              'it so it never paints behind the sidebar.');

      if (zoom > 1.0) {
        // Sanity: without the clip the same painter DOES overrun the canvas at
        // zoom > 1, so the test is exercising a real containment (not a no-op).
        final unclipped = await bleedPixels(zoom: zoom, clip: false);
        expect(unclipped, greaterThan(0),
            reason:
                'At zoom $zoom the UNCLIPPED survey background must overrun '
                'the canvas (the bug the ClipRect fixes); got $unclipped.');
      }
    }
  });
}
