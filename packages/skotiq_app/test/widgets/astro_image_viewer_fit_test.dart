import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/astro_image_viewer.dart';

void main() {
  testWidgets('an image smaller than the view is fitted to its center',
      (tester) async {
    const width = 200;
    const height = 100;
    final rgba = Uint8List(width * height * 4)
      ..fillRange(0, width * height * 4, 200);

    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 800,
            height: 600,
            child: AstroImageViewer(
              imageData: rgba,
              width: width,
              height: height,
            ),
          ),
        ),
      ),
    );
    // Decoding the pixels is real async; the fit lands on the next frame.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump();

    final image = find.descendant(
      of: find.byType(AstroImageViewer),
      matching: find.byType(CustomPaint),
    );
    // Fit is 4x (800 / 200), so the image fills the width and sits midway
    // down: 800 x 400 from y = 100.
    expect(tester.getTopLeft(image.last), const Offset(0, 100));
    expect(tester.getBottomRight(image.last), const Offset(800, 500));
  });
}
