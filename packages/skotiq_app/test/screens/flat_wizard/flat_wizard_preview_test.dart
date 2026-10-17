// The flat wizard's largest panel must not deny frames it just wrote.
//
// The capture loop publishes the frame's raw display BYTES, and the panel
// cannot render bytes without the frame's dimensions — so every captured frame
// falls through to the empty state, and the preview reads "No flat captured yet
// / Start capture or test exposure to see preview" through an entire Quick
// Capture run that is writing FITS to disk.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/widgets/flat_preview_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

CapturedImageResult _frame() => CapturedImageResult(
      width: 8,
      height: 8,
      displayData: Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, 200),
      histogram: List.filled(256, 0),
      stats: const ImageStatsResult(
        min: 0,
        max: 65535,
        mean: 32584,
        median: 32584,
        stdDev: 100,
        starCount: 0,
      ),
      exposureTime: 7.86,
      timestamp: '2026-08-11T10:34:51Z',
    );

Future<HarnessHandle> _pump(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const FlatPreviewPanel(),
    size: const Size(900, 700),
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 100));
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a captured flat replaces the empty state', (tester) async {
    final handle = await _pump(tester);
    expect(find.text('No flat captured yet'), findsOneWidget);

    // Exactly what the capture loop publishes for a frame it has just saved.
    handle.container
        .read(flatWizardProvider.notifier)
        .setLastImage('/tmp/2026-08-11/Ha/Flat_Ha_1.fits', _frame());
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('No flat captured yet'),
      findsNothing,
      reason:
          'a frame is on disk; the panel is the only thing saying otherwise',
    );
    // The panel needs dimensions, so the published value must be the frame
    // itself. `lastImageData` is `Object?` on the state; the setter's type is
    // what keeps the unrenderable shape out.
    expect(
      handle.container.read(flatWizardProvider).lastImageData,
      isA<CapturedImageResult>(),
    );
  });
}
