// The fullscreen frame inspector is an OPAQUE full-screen route whose only
// exit is a 40 px circle in the top-right corner. There is no barrier to click
// away and, off Android, no system back button — so when Escape did nothing the
// operator had exactly one 40 px target to find, and a keyboard user had none.
//
// Reproduced live on 2026-08-09 at a 420x900 window: tapping the live preview
// pushed the viewer, Escape was pressed, and a cropped screenshot showed the
// close button still on screen with the route still up. Every other modal in
// this app (the pre-flight dialog, the focus-model overflow menu) closes on
// Escape, so this route quietly broke the habit.
//
// These tests fail if the Escape binding is removed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/fullscreen_image_viewer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

CapturedImageData _frame() => CapturedImageData(
      width: 4,
      height: 4,
      displayData: Uint8List(4 * 4 * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 100, stdDev: 5),
      capturedAt: DateTime.utc(2026, 8, 9, 21),
      settings: const ExposureSettings(
        exposureTime: 2,
        gain: 100,
        offset: 10,
      ),
      filePath: '/tmp/fullscreen_probe.fits',
    );

Future<void> _pushViewer(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => FullscreenImageViewer.show(context, _frame()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // Bounded pumps, not pumpAndSettle: the preview widget keeps an animation
  // running, so settling never completes in this route.
  await _settle(tester);
  expect(find.byType(FullscreenImageViewer), findsOneWidget);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('Escape closes the fullscreen frame inspector', (tester) async {
    await _pushViewer(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    expect(
      find.byType(FullscreenImageViewer),
      findsNothing,
      reason: 'Escape must dismiss the fullscreen viewer; on a desktop-sized '
          'window the close button is the only other way out.',
    );
  });

  testWidgets('the close button carries an accessible name', (tester) async {
    await _pushViewer(tester);

    // The live AT-SPI dump of this route was one `button:` with an empty name,
    // so the sole exit was unreachable by name for assistive tech.
    expect(find.bySemanticsLabel('Close fullscreen image'), findsOneWidget);
  });
}
