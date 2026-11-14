import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/image_preview/preview_downscale.dart';

Uint8List _rgba(int width, int height, List<int> color) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = color[i % 4];
  }
  return bytes;
}

Future<Uint8List> _engineResize(Uint8List pixels, int width, int height,
    int targetWidth, int targetHeight) async {
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, width, height, ui.PixelFormat.rgba8888, decoded.complete,
      targetWidth: targetWidth, targetHeight: targetHeight);
  final image = await decoded.future;
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
  } finally {
    image.dispose();
  }
}

Future<Uint8List?> _resize(Uint8List pixels, int width, int height,
        int targetWidth, int targetHeight,
        {bool Function()? isCancelled}) =>
    downscalePreviewRgba(
      pixels: pixels,
      width: width,
      height: height,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      isCancelled: isCancelled ?? () => false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native resolution retains the exact source buffer', () async {
    final pixels = _rgba(13, 7, [80, 40, 20, 160]);
    expect(identical(await _resize(pixels, 13, 7, 13, 7), pixels), isTrue);
  });

  test('odd asymmetric reductions preserve constant premultiplied RGBA',
      () async {
    final pixels = _rgba(13, 7, [80, 40, 20, 160]);
    final reduced = await _resize(pixels, 13, 7, 5, 3);
    expect(reduced, _rgba(5, 3, [80, 40, 20, 160]));
    expect(pixels, _rgba(13, 7, [80, 40, 20, 160]));
  });

  test('twofold reduction agrees with Skia linear decoding within one level',
      () async {
    final pixels = _rgba(16, 12, [0, 0, 0, 255]);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = (i * 13 + 17) % 256;
      pixels[i + 1] = (i * 19 + 31) % 256;
      pixels[i + 2] = (i * 23 + 43) % 256;
    }
    final reduced = (await _resize(pixels, 16, 12, 8, 6))!;
    final expected = await _engineResize(pixels, 16, 12, 8, 6);
    for (var i = 0; i < reduced.length; i++) {
      expect(reduced[i], closeTo(expected[i], 1), reason: 'channel $i');
    }
  });

  test('a narrow faint star survives every phase of a fourfold reduction',
      () async {
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final pixels = _rgba(8, 8, [0, 0, 0, 255]);
        final index = (y * 8 + x) * 4;
        pixels[index] = pixels[index + 1] = pixels[index + 2] = 64;
        final reduced = (await _resize(pixels, 8, 8, 2, 2))!;
        final red = [for (var i = 0; i < reduced.length; i += 4) reduced[i]];
        expect(red.reduce((a, b) => a + b), 4,
            reason: 'star at ($x, $y) must contribute its covered area');
        expect(red[(y ~/ 4) * 2 + x ~/ 4], 4);
      }
    }
  });

  test('noninteger reduction preserves star contribution including edges',
      () async {
    const area = (7 * 5) / (3 * 2);
    for (var y = 0; y < 5; y++) {
      for (var x = 0; x < 7; x++) {
        final pixels = _rgba(7, 5, [0, 0, 0, 255]);
        pixels[(y * 7 + x) * 4] = 120;
        final reduced = (await _resize(pixels, 7, 5, 3, 2))!;
        final sum = [for (var i = 0; i < reduced.length; i += 4) reduced[i]]
            .reduce((a, b) => a + b);
        // A source pixel touches at most four destinations; each rounds by
        // at most half one byte level. Brightness is averaged, not peaked.
        expect(sum * area, closeTo(120, 2 * area), reason: 'star at ($x, $y)');
        expect(sum, greaterThan(0));
      }
    }
  });

  test('fine checkerboard averages instead of aliasing to black or white',
      () async {
    final pixels = _rgba(8, 8, [0, 0, 0, 255]);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        if ((x + y).isOdd) pixels[(y * 8 + x) * 4] = 255;
      }
    }
    expect((await _resize(pixels, 8, 8, 1, 1))![0], 128);
  });

  test('large resize lets other events run and cancels obsolete work',
      () async {
    final pixels = _rgba(1024, 1024, [50, 30, 10, 255]);
    var cancelled = false;
    var checks = 0;
    final result = _resize(pixels, 1024, 1024, 300, 300, isCancelled: () {
      checks++;
      return cancelled;
    });
    Timer.run(() => cancelled = true);
    expect(await result, isNull);
    expect(checks, greaterThanOrEqualTo(3),
        reason: 'cancellation runs after a bounded batch, not just at entry');
  });

  test('rejects invalid dimensions instead of decoding a mismatched frame',
      () async {
    await expectLater(_resize(Uint8List(16), 3, 2, 1, 1), throwsArgumentError);
    await expectLater(_resize(Uint8List(16), 2, 2, 3, 2), throwsArgumentError);
  });
}
