import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/image_preview/image_display.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

CapturedImageData _frame(int width, int height, int marker) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = marker;
    pixels[i + 3] = 255;
  }
  return CapturedImageData(
    width: width,
    height: height,
    displayData: pixels,
    histogram: List<int>.filled(256, 0),
    stats: const ImageStats(mean: 100, stdDev: 5),
    capturedAt: DateTime.utc(2026, 11, 13, 0, 0, marker),
    settings: const ExposureSettings(exposureTime: 1, gain: 100, offset: 10),
    filePath: '/tmp/preview_$marker.fits',
  );
}

Future<void> _pump(
  WidgetTester tester,
  CapturedImageData frame, {
  double zoom = 1,
  double dpr = 1,
  double width = 100,
  double height = 100,
  bool viewport = true,
  int? targetWidth,
  Offset pan = Offset.zero,
}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(ProviderScope(
      overrides: [stretchedImageProvider.overrideWith((ref) async => null)],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: ImageDisplayWidget(
                imageData: frame,
                zoomLevel: zoom,
                panOffset: pan,
                downscaleToViewport: viewport,
                targetWidth: targetWidth,
              ),
            ),
          ),
        ),
      ),
    ));
  });
}

dynamic _state(WidgetTester tester) =>
    tester.state<State<ImageDisplayWidget>>(find.byType(ImageDisplayWidget));

Future<ui.Image> _decoded(
    WidgetTester tester, CapturedImageData frame, int width, int height,
    {Uint8List? expectedPixels}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 1));
    final state = _state(tester);
    final image = state.debugDecodedImage as ui.Image?;
    if (identical(
            state.debugDecodedPixels, expectedPixels ?? frame.displayData) &&
        image?.width == width &&
        image?.height == height) {
      return image!;
    }
  }
  final image = _state(tester).debugDecodedImage as ui.Image?;
  fail('Expected the latest $width x $height preview; '
      'got ${image?.width} x ${image?.height}, matching pixels: '
      '${identical(_state(tester).debugDecodedPixels, expectedPixels ?? frame.displayData)}');
}

Finder _paint() => find.descendant(
      of: find.byType(ImageDisplayWidget),
      matching: find.byType(CustomPaint),
    );

void main() {
  testWidgets(
      'fit uses physical viewport pixels and native zoom restores source',
      (tester) async {
    final frame = _frame(400, 200, 32);
    await _pump(tester, frame);
    final fitted = await _decoded(tester, frame, 100, 50);
    final geometry = tester.getRect(_paint());
    expect(geometry.size, const Size(100, 100));

    await _pump(tester, frame, dpr: 2);
    final retina = await _decoded(tester, frame, 200, 100);
    expect(fitted.debugDisposed, isTrue);
    expect(tester.getRect(_paint()), geometry,
        reason:
            'DPR changes texture resolution, not source-coordinate geometry');

    await _pump(tester, frame, zoom: 4, dpr: 2);
    final native = await _decoded(tester, frame, 400, 200);
    expect(retina.debugDisposed, isTrue);
    expect(native.width * native.height, frame.width * frame.height);
    expect(identical(_state(tester).debugDecodedPixels, frame.displayData),
        isTrue);
  });

  testWidgets('fullscreen default retains native pixels and pan reuses texture',
      (tester) async {
    final frame = _frame(400, 200, 64);
    await _pump(tester, frame, viewport: false);
    final native = await _decoded(tester, frame, 400, 200);
    await _pump(tester, frame, viewport: false, pan: const Offset(12, -4));
    expect(await _decoded(tester, frame, 400, 200), same(native));
    expect(native.debugDisposed, isFalse);
  });

  testWidgets('viewport resize and one-dimension hints keep source aspect',
      (tester) async {
    final frame = _frame(301, 151, 96);
    await _pump(tester, frame, width: 100, height: 80);
    await _decoded(tester, frame, 100, 51);
    final paint = tester.widget<CustomPaint>(_paint());
    expect(paint.size, const Size(301, 151),
        reason: 'integer texture rounding must not redefine the source aspect');

    await _pump(tester, frame, width: 70, height: 80);
    await _decoded(tester, frame, 70, 36);

    await _pump(tester, frame, viewport: false, targetWidth: 120);
    await _decoded(tester, frame, 120, 60);
  });

  testWidgets('new frame and zoom coalesce without mixing dimensions and bytes',
      (tester) async {
    final first = _frame(1400, 900, 64);
    final second = _frame(500, 300, 128);
    final latest = _frame(320, 240, 192);
    await _pump(tester, first);
    await _pump(tester, second, zoom: 2);
    await _pump(tester, latest);
    final image = await _decoded(tester, latest, 100, 75);
    final bytes = (await tester
        .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    expect(bytes.getUint8(0), 192);
    expect(bytes.getUint8(3), 255);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(image.debugDisposed, isTrue);
  });

  testWidgets('rapid zoom changes finish at the latest size and pan reuses it',
      (tester) async {
    final frame = _frame(1400, 900, 80);
    for (final zoom in [1.0, 1.1, 2.0, 4.0, 1.5]) {
      await _pump(tester, frame, zoom: zoom);
    }
    final image = await _decoded(tester, frame, 150, 97);
    await _pump(tester, frame, zoom: 1.5, pan: const Offset(12, -6));
    expect(await _decoded(tester, frame, 150, 97), same(image));
  });

  testWidgets('resize during stretch loading keeps the last rendered pixels',
      (tester) async {
    final frame = _frame(400, 200, 64);
    final linear = _frame(400, 200, 128).displayData;
    final rendering = StateProvider<Future<Uint8List?>>(
        (ref) => Future<Uint8List?>.value(linear));
    final container = ProviderContainer(overrides: [
      stretchedImageProvider.overrideWith((ref) => ref.watch(rendering)),
    ]);
    addTearDown(container.dispose);
    container.read(currentImageProvider.notifier).state = frame;

    Future<void> pump(double zoom) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 1),
              child: Center(
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: ImageDisplayWidget(
                    imageData: frame,
                    zoomLevel: zoom,
                    panOffset: Offset.zero,
                    downscaleToViewport: true,
                  ),
                ),
              ),
            ),
          ),
        ));
      });
    }

    await pump(1);
    final shown =
        await _decoded(tester, frame, 100, 50, expectedPixels: linear);
    final pending = Completer<Uint8List?>();
    container.read(rendering.notifier).state = pending.future;
    await pump(2);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(_state(tester).debugDecodedImage, same(shown));
    expect(_state(tester).debugDecodedPixels, same(linear));

    pending.complete(linear);
    await _decoded(tester, frame, 200, 100, expectedPixels: linear);
    expect(shown.debugDisposed, isTrue);
  });

  testWidgets('unmount cancels a pending resize without publishing a texture',
      (tester) async {
    await _pump(tester, _frame(1400, 900, 48));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(tester.takeException(), isNull);
  });
}
