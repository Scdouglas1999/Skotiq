import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/image_display.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The preview must release the texture of the frame it replaces.
///
/// `ui.Image` holds its pixels outside the Dart heap, so letting the reference
/// go does not free them — only `dispose()` does. This widget swapped
/// `_decodedImage` on every new frame and had no `dispose()` at all, so a
/// session leaked one full-resolution texture per frame (65 MB at the rig's
/// 4656x3520). Every sibling image widget in the app already disposes; this one
/// did not, and it is the one mounted at native resolution on the Imaging
/// screen.
void main() {
  CapturedImageData frame(int marker) => CapturedImageData(
        width: 4,
        height: 4,
        displayData: Uint8List(4 * 4 * 4)..[0] = marker,
        histogram: List<int>.filled(256, 0),
        stats: const ImageStats(mean: 100, stdDev: 5),
        capturedAt: DateTime.utc(2026, 9, 13, 23, marker),
        settings: const ExposureSettings(
          exposureTime: 1,
          gain: 139,
          offset: 21,
        ),
        filePath: '/tmp/frame_$marker.fits',
      );

  Future<void> pumpFrame(WidgetTester tester, CapturedImageData data) async {
    // decodeImageFromPixels hands the work to the engine, so the callback only
    // runs on a real event loop — runAsync, not pump, is what lets it land.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // Keeps the widget off the auto-stretch chain, which reaches the
            // real settings database. This test is about texture ownership.
            stretchedImageProvider.overrideWith((ref) async => null),
          ],
          child: MaterialApp(
            home: ImageDisplayWidget(
              imageData: data,
              zoomLevel: 1,
              panOffset: Offset.zero,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  testWidgets('releases the previous frame texture when a new frame arrives', (
    tester,
  ) async {
    await pumpFrame(tester, frame(1));

    final state = tester.state<State<ImageDisplayWidget>>(
      find.byType(ImageDisplayWidget),
    );
    final first = (state as dynamic).debugDecodedImage;
    expect(first, isNotNull, reason: 'the first frame should have decoded');
    expect(first.debugDisposed, isFalse);

    await pumpFrame(tester, frame(2));

    expect(
      first.debugDisposed,
      isTrue,
      reason: 'the replaced texture was leaked',
    );
    final second = (state as dynamic).debugDecodedImage;
    expect(second, isNotNull);
    expect(second.debugDisposed, isFalse);
  });

  testWidgets('releases the live texture when the widget is disposed', (
    tester,
  ) async {
    await pumpFrame(tester, frame(3));

    final state = tester.state<State<ImageDisplayWidget>>(
      find.byType(ImageDisplayWidget),
    );
    final decoded = (state as dynamic).debugDecodedImage;
    expect(decoded, isNotNull);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stretchedImageProvider.overrideWith((ref) async => null),
          ],
          child: const MaterialApp(home: SizedBox.shrink()),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    expect(
      decoded.debugDisposed,
      isTrue,
      reason: 'the texture outlived the widget that owned it',
    );
  });
}
