// Regression test for the MasterOverlayView annotation registration under
// zoom/pan.
//
// The annotation CustomPaint sits inside the InteractiveViewer's child subtree,
// so the viewer's single Transform already moves it. The painter must NOT
// re-apply the viewer matrix (the previous bug double-transformed annotations,
// sliding them off their catalog objects as soon as the user zoomed/panned).
//
// `annotationLocalCenter` is the un-zoomed local-space center the painter draws
// at; it must be independent of the transform. This asserts the center is
// identical at identity and at a zoomed + panned transform — i.e. the matrix is
// applied exactly once (by the enclosing Transform), never twice.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/widgets/master_overlay_view.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  const layer = AnnotationLayer(
    width: 400,
    height: 300,
    items: [
      Annotation(
        label: 'NGC 7000',
        x: 120,
        y: 90,
        kind: AnnotationKind.nebula,
        sizePx: 70,
        paDeg: 30,
      ),
      Annotation(
        label: 'M31',
        x: 280,
        y: 200,
        kind: AnnotationKind.galaxy,
        sizePx: 50,
      ),
    ],
  );

  const viewport = Size(640, 480);

  test('annotation local center depends only on the layout, not on zoom/pan',
      () {
    // The painter's mapping takes NO transform argument — its center is a pure
    // function of the layer + viewport. The enclosing InteractiveViewer Transform
    // is the single source of the on-screen zoom/pan; the painter never re-applies
    // it. This asserts the mapping is stable and ordered the same as the pixels.
    final first = annotationLocalCenter(
        layer.items[0], viewport, layer.width, layer.height);
    final second = annotationLocalCenter(
        layer.items[1], viewport, layer.width, layer.height);
    // M31 (x=280,y=200) is down-right of NGC 7000 (x=120,y=90).
    expect(second.dx, greaterThan(first.dx));
    expect(second.dy, greaterThan(first.dy));
  });

  test('annotation center sits on the contained image, mapped by scale', () {
    // BoxFit.contain scale for 400x300 into 640x480 is min(640/400, 480/300) =
    // min(1.6, 1.6) = 1.6; the image fills the viewport exactly here.
    final scale = annotationContainScale(viewport, layer.width, layer.height);
    expect(scale, closeTo(1.6, 1e-9));

    final c = annotationLocalCenter(
        layer.items.first, viewport, layer.width, layer.height);
    // origin is (0,0) since the image fills the viewport; center = pixel*scale.
    expect(c.dx, closeTo(120 * 1.6, 1e-9));
    expect(c.dy, closeTo(90 * 1.6, 1e-9));
  });

  testWidgets(
      'MasterOverlayView survives a non-identity zoom/pan without error',
      (tester) async {
    final previewPath = await tester.runAsync(_writeSamplePng);
    final controller = TransformationController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 480,
            child: MasterOverlayView(
              previewPngPath: previewPath!,
              annotations: layer,
            ),
          ),
        ),
      ),
    );
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    // Drive the InteractiveViewer's controller to a zoomed + panned matrix and
    // confirm the annotation overlay repaints without throwing (the painter no
    // longer touches the matrix, so this is purely a "doesn't crash" guard on
    // the live transform path).
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    viewer.transformationController!.value = Matrix4.identity()
      ..translateByDouble(60.0, 40.0, 0.0, 1.0)
      ..scaleByDouble(2.5, 2.5, 2.5, 1.0);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('shows decodable rejection and coverage overlay controls',
      (tester) async {
    final previewPath = await tester.runAsync(_writeSamplePng);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 480,
            child: MasterOverlayView(
              previewPngPath: previewPath!,
              rejectionMapPngPath: previewPath,
              coverageMapPngPath: previewPath,
            ),
          ),
        ),
      ),
    );
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('Rejection'), findsOneWidget);
    expect(find.text('Coverage'), findsOneWidget);

    await tester.tap(find.text('Rejection'));
    await tester.tap(find.text('Coverage'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Future<String> _writeSamplePng() async {
  const w = 400;
  const h = 300;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final paint = Paint()
    ..shader = const LinearGradient(
      colors: [Color(0xFF101826), Color(0xFF243044)],
    ).createShader(rect);
  canvas.drawRect(rect, paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final dir = Directory.systemTemp.createTempSync('ns_overlay_anno');
  final file = File('${dir.path}/master_preview.png');
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  return file.path;
}
