// Regression guard for the blank-image bug on the Imaging screen.
//
// The live preview's inner Stack (in LivePreviewArea) holds only Positioned
// children once a frame is present. The preview column that hosts it must
// therefore hand it a TIGHT width — i.e. the column must stretch its children.
// When the column fell back to its default CrossAxisAlignment.center the Stack
// received a LOOSE width and collapsed to zero width (height stayed correct via
// the Expanded), so captured frames rendered blank even though the identical
// ImageDisplayWidget on the Dashboard — hosted in a stretch column — showed
// them. This test pins the preview's width > 0 so that regression can't return
// silently.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/image_display.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'imaging preview renders the current frame with a non-zero footprint',
      (tester) async {
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);

    final frame = CapturedImageData(
      width: 64,
      height: 48,
      displayData: Uint8List(64 * 48 * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 0, stdDev: 0),
      capturedAt: DateTime.utc(2026, 6, 3, 21, 0, 0),
      settings:
          const ExposureSettings(exposureTime: 1.0, gain: 100, offset: 10),
      filePath: '/tmp/light_001.fits',
    );

    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drain(tester);
    handle.container.read(currentImageProvider.notifier).state = frame;
    await _drain(tester);

    final finder = find.byType(ImageDisplayWidget);
    expect(finder, findsOneWidget,
        reason: 'A published frame must mount the image display widget.');
    final size = tester.getSize(finder);
    expect(size.width, greaterThan(1),
        reason: 'The preview collapsed to zero width — captured frames render '
            'blank. The preview column must stretch its children so the '
            'inner (Positioned-only) Stack gets a tight width.');
    expect(size.height, greaterThan(1),
        reason: 'The preview must also have a real height.');
  });
}
