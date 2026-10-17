// The shared frame-preview ladder decodes at the cell it lands in.
//
// `FrameThumbnail` is the ladder behind the Dashboard cockpit strip, the
// Tonight preview panel, the sequencer's exposure strip and the run
// dashboard's history rail. All four paint a ~72-100 px tile, and all four
// used to decode the backend's 512 px JPEG at 512 px — a megabyte of RGBA per
// tile, held in an image cache with a 100 MB budget.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/frame_thumbnail_loader.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A 1x1 PNG — the smallest thing `Image.memory` will decode.
const _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

Widget _harness({
  required Widget child,
  required double tilePx,
  double devicePixelRatio = 1.0,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: devicePixelRatio),
        child: Scaffold(
          body: Center(
            child: SizedBox(width: tilePx, height: tilePx, child: child),
          ),
        ),
      ),
    ),
  );
}

FrameThumbnail _thumbnail(BuildContext context, Future<Uint8List?> bytes) =>
    FrameThumbnail(
      bytesFuture: bytes,
      fallbackFilePath: '/frames/L_0001.fits',
      colors: SkotiqColors.of(context),
    );

void main() {
  testWidgets('the backend thumbnail decodes at the tile, not at 512 px',
      (tester) async {
    final bytes = Future<Uint8List?>.value(
      Uint8List.fromList(_onePixelPng),
    );
    await tester.pumpWidget(
      _harness(
        tilePx: 72,
        child: Builder(builder: (context) => _thumbnail(context, bytes)),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(provider.width, 72);
    expect(provider.height, isNull, reason: 'width alone preserves aspect');
  });

  testWidgets('the decode follows the device pixel ratio', (tester) async {
    final bytes = Future<Uint8List?>.value(
      Uint8List.fromList(_onePixelPng),
    );
    await tester.pumpWidget(
      _harness(
        tilePx: 72,
        devicePixelRatio: 2.0,
        child: Builder(builder: (context) => _thumbnail(context, bytes)),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as ResizeImage).width, 144);
  });

  testWidgets('a bigger tile gets a bigger decode', (tester) async {
    final bytes = Future<Uint8List?>.value(
      Uint8List.fromList(_onePixelPng),
    );
    await tester.pumpWidget(
      _harness(
        tilePx: 200,
        child: Builder(builder: (context) => _thumbnail(context, bytes)),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as ResizeImage).width, 200);
  });

  testWidgets('the local-file rung is sized the same way', (tester) async {
    // A frame with no backend thumbnail but a Flutter-decodable file. The
    // ladder used to hand `Image.file` the whole PNG or TIFF at full size,
    // which for a master preview is a 16 Mpx decode into a 72 px box.
    await tester.pumpWidget(
      _harness(
        tilePx: 72,
        child: Builder(
          builder: (context) => FrameThumbnail(
            bytesFuture: Future<Uint8List?>.value(null),
            fallbackFilePath: '/frames/preview.png',
            colors: SkotiqColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    expect(provider.width, 72);
    expect(provider.imageProvider, isA<FileImage>());
  });

  testWidgets(
      'a frame with neither bytes nor a decodable file shows the '
      'placeholder, not a broken image', (tester) async {
    await tester.pumpWidget(
      _harness(
        tilePx: 72,
        child: Builder(
          builder: (context) => FrameThumbnail(
            bytesFuture: Future<Uint8List?>.value(null),
            fallbackFilePath: '/frames/L_0001.fits',
            colors: SkotiqColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.byType(Icon), findsOneWidget);
  });
}
