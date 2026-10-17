import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/display_buffer_jpeg.dart';

const _stats = ImageStatsResult(
  min: 0,
  max: 0,
  mean: 0,
  median: 0,
  stdDev: 0,
  starCount: 0,
);

CapturedImageResult imageOf(int width, int height, List<int> pixels) =>
    CapturedImageResult(
      width: width,
      height: height,
      displayData: pixels,
      histogram: const [1],
      stats: _stats,
      exposureTime: 1,
      timestamp: '2026-07-23T19:34:35-04:00',
    );

Uint8List gradient(int width, int height) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = i % 251;
    pixels[i + 1] = (i ~/ 7) % 251;
    pixels[i + 2] = (i ~/ 13) % 251;
    pixels[i + 3] = 255;
  }
  return pixels;
}

void main() {
  test('offset-less native frame timestamps are serialized as UTC', () {
    expect(
      capturedImageTimestampUtc('2026-07-23T23:34:35'),
      '2026-07-23T23:34:35.000Z',
    );
  });

  test('JPEG metadata preserves the captured instant across offsets', () async {
    final image = imageOf(1, 1, const [0, 0, 0, 255]);

    final encoded = await encodeCapturedImageDisplayBufferToJpeg(image);
    expect(encoded, isNotNull);
    final metadata = decodeImageMetaHeader(encoded!.metaHeaderValue);
    expect(metadata['timestamp'], '2026-07-23T23:34:35.000Z');
  });

  test('a display buffer of the wrong length is rejected', () async {
    expect(
      await encodeCapturedImageDisplayBufferToJpeg(
        imageOf(2, 2, const [0, 0, 0, 255]),
      ),
      isNull,
    );
  });

  test('the encode does not block the calling isolate', () async {
    // Large enough that the inline implementation measurably stalled the
    // event loop: 285 ms and zero timer ticks before this moved off-isolate.
    const w = 1800;
    const h = 1800;
    final image = imageOf(w, h, gradient(w, h));

    var ticks = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks++;
    });
    final sw = Stopwatch()..start();
    final encoded = await encodeCapturedImageDisplayBufferToJpeg(image);
    sw.stop();
    ticker.cancel();

    expect(encoded, isNotNull);
    expect(encoded!.sourceWidth, w);
    expect(
      sw.elapsedMilliseconds,
      greaterThan(50),
      reason:
          'the encode must be slow enough for this assertion to mean '
          'anything; if it is not, raise the image size',
    );
    expect(
      ticks,
      greaterThan(0),
      reason: 'the caller\'s event loop must keep running during the encode',
    );
  });

  test(
    'maxWidth downscales and reports both source and encoded sizes',
    () async {
      final encoded = await encodeCapturedImageDisplayBufferToJpeg(
        imageOf(64, 32, gradient(64, 32)),
        maxWidth: 16,
      );

      expect(encoded, isNotNull);
      expect(encoded!.sourceWidth, 64);
      expect(encoded.sourceHeight, 32);
      expect(encoded.encodedWidth, 16);
      expect(encoded.encodedHeight, 8);
      final metadata = decodeImageMetaHeader(encoded.metaHeaderValue);
      expect(metadata['width'], 64);
      expect(metadata['encodedWidth'], 16);
    },
  );

  test('a Uint8List view and an equal List<int> encode identically', () async {
    const w = 8;
    const h = 8;
    final pixels = gradient(w, h);

    // A view with a non-zero offset: the encoder must honour the view bounds
    // rather than the whole backing ByteBuffer.
    final backing = Uint8List(pixels.length + 64)
      ..setRange(64, 64 + pixels.length, pixels);
    final view = Uint8List.sublistView(backing, 64);

    final fromView = await encodeCapturedImageDisplayBufferToJpeg(
      imageOf(w, h, view),
    );
    final fromList = await encodeCapturedImageDisplayBufferToJpeg(
      imageOf(w, h, pixels.toList()),
    );

    expect(fromView, isNotNull);
    expect(fromList, isNotNull);
    expect(fromView!.bytes, fromList!.bytes);
  });
}
