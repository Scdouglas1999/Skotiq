@Tags(['golden'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/screens/session_review/widgets/narrowband_mixer_panel.dart';
import 'package:skotiq_app/screens/session_review/widgets/master_overlay_view.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'surface_golden_harness.dart';

/// Renders [NarrowbandMixerPanel] and [MasterOverlayView] to inspectable review
/// PNGs under `docs/design/goldens/`. These are eyeballed by a reviewer, not
/// pixel-diff guards, so the assertions only check a real, non-empty image was
/// produced.
void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('morning report — narrowband mixer panel (dark)', (tester) async {
    tester.view.physicalSize = const Size(620, 940);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: SkotiqColors.dark.background,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 520,
                height: 880,
                child: Padding(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                  child: NarrowbandMixerPanel(
                    channels: const [
                      NarrowbandChannelRef(
                          masterId: 1, filter: 'SII', label: 'SII master'),
                      NarrowbandChannelRef(
                          masterId: 2, filter: 'Ha', label: 'Ha master'),
                      NarrowbandChannelRef(
                          masterId: 3, filter: 'OIII', label: 'OIII master'),
                    ],
                    onApply: (_, __) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-narrowband-mixer.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('morning report — master overlay view (dark)', (tester) async {
    tester.view.physicalSize = const Size(700, 620);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // The overlay view loads an on-disk preview PNG; synthesize a small one.
    final previewPath = await tester.runAsync(() => _writeSamplePng());

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: SkotiqColors.dark.background,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 640,
                height: 560,
                child: MasterOverlayView(
                  previewPngPath: previewPath!,
                  annotations: _sampleLayer(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Let Image.file decode the synthesized PNG.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-master-overlay.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });
}

AnnotationLayer _sampleLayer() => const AnnotationLayer(
      width: 400,
      height: 300,
      items: [
        Annotation(
            label: 'NGC 7000',
            x: 120,
            y: 90,
            kind: AnnotationKind.nebula,
            sizePx: 70,
            paDeg: 30),
        Annotation(
            label: 'M31',
            x: 280,
            y: 200,
            kind: AnnotationKind.galaxy,
            sizePx: 50),
        Annotation(
            label: 'Deneb',
            x: 200,
            y: 60,
            kind: AnnotationKind.star,
            sizePx: 8),
      ],
    );

/// Writes a 400×300 RGBA gradient PNG to a temp file for the hero base layer.
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
  final dir = Directory.systemTemp.createTempSync('sk_overlay_golden');
  final file = File('${dir.path}/master_preview.png');
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  return file.path;
}
