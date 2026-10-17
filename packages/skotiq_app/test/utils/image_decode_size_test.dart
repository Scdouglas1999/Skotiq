// Thumbnail cells must decode at the size they display.
//
// The tree carried not one `cacheWidth`, `cacheHeight` or `ResizeImage`, so
// every thumbnail surface decoded its image at full encoded resolution and
// parked that decode in `PaintingBinding.instance.imageCache`: a 512 px frame
// thumbnail in a 72 px cell is 1 MB of RGBA for 20 KB of visible pixels, and a
// full-frame master preview PNG in the same cell is 65 MB. Against the cache's
// 100 MB default budget a night's rail evicts and re-decodes itself forever,
// and on the desktop every re-decode was a fresh blocking FITS read.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/image_decode_size.dart';

/// Builds a context at a chosen device pixel ratio and hands back what
/// [thumbnailDecodeWidth] answers for [logicalWidth].
Future<int?> decodeWidthAt(
  WidgetTester tester, {
  required double devicePixelRatio,
  required double logicalWidth,
}) async {
  int? answer;
  var asked = false;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(devicePixelRatio: devicePixelRatio),
      child: Builder(
        builder: (context) {
          answer = thumbnailDecodeWidth(context, logicalWidth);
          asked = true;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  expect(asked, isTrue);
  return answer;
}

void main() {
  testWidgets('a 1x cell decodes at its logical width', (tester) async {
    expect(
      await decodeWidthAt(tester, devicePixelRatio: 1.0, logicalWidth: 72),
      72,
    );
  });

  testWidgets('a hidpi cell decodes at its physical width', (tester) async {
    // The owner's laptop runs at a fractional ratio; asking for the logical
    // width there would paint a soft thumbnail, which is the failure mode that
    // makes people reach for "just decode it full size".
    expect(
      await decodeWidthAt(tester, devicePixelRatio: 1.5, logicalWidth: 72),
      108,
    );
    expect(
      await decodeWidthAt(tester, devicePixelRatio: 2.0, logicalWidth: 100),
      200,
    );
  });

  testWidgets('a fractional result rounds up, never down', (tester) async {
    // Rounding down would decode one pixel short of the box and upscale it.
    expect(
      await decodeWidthAt(tester, devicePixelRatio: 1.25, logicalWidth: 73),
      92, // 91.25 -> 92
    );
  });

  testWidgets('an unbounded box asks for no particular size', (tester) async {
    // A row without an Expanded gives infinite maxWidth. There is nothing to
    // derive a size from, and guessing one would crop or blur the image, so
    // the decode stays at the file's own resolution.
    expect(
      await decodeWidthAt(
        tester,
        devicePixelRatio: 2.0,
        logicalWidth: double.infinity,
      ),
      isNull,
    );
  });

  testWidgets('a collapsed box asks for no particular size', (tester) async {
    // A cell measured during a build that has not laid out yet, or one
    // genuinely collapsed to nothing: `cacheWidth: 0` is an error in Flutter,
    // so null is the only correct answer.
    for (final width in <double>[0, -12]) {
      expect(
        await decodeWidthAt(
          tester,
          devicePixelRatio: 2.0,
          logicalWidth: width,
        ),
        isNull,
        reason: 'width $width',
      );
    }
  });

  testWidgets('a NaN width asks for no particular size', (tester) async {
    expect(
      await decodeWidthAt(
        tester,
        devicePixelRatio: 2.0,
        logicalWidth: double.nan,
      ),
      isNull,
    );
  });
}
