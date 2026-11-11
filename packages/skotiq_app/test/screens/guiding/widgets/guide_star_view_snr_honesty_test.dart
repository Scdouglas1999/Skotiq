// The Guide Star panel never badges a bright, just-selected star `SNR: 0.0`
// because the loop is stopped.
//
// Repro: Guiding ▸ Stop the loop (the cached frame stays on screen) ▸ Deselect
// ▸ Auto Select. The panel renders the star crop with crosshairs on it while
// the badge reads "SNR: 0.0" — for a star the log says was chosen out of 107
// detections. The same panel reads "SNR: 445.9" while looping, and pressing
// Loop Exposures again produces "SNR: 70.6" within 12 s. Zero is what an
// unmeasured field arrives as, and on a badge coloured red below 5 it reads as
// the worst star in the sky rather than as "not measured".
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Uint8List _crop(int width, int height) {
  // 16-bit little-endian payload, mid-grey so the widget accepts it as valid.
  return Uint8List.fromList(
    List<int>.generate(width * height * 2, (i) => i.isEven ? 0x00 : 0x40),
  );
}

Future<void> _pump(WidgetTester tester, double snr) {
  return tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 200,
          child: GuideStarView(
            pixels: _crop(50, 50),
            width: 50,
            height: 50,
            starX: 25,
            starY: 25,
            snr: snr,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('an unmeasured SNR reads as a blank, not as 0.0', (tester) async {
    await _pump(tester, 0);
    await tester.pump();

    expect(find.text('SNR: 0.0'), findsNothing);
    expect(find.text('SNR: —'), findsOneWidget);
  });

  testWidgets('a measured SNR is still printed', (tester) async {
    // The complement: the badge must not go blank on a real reading.
    await _pump(tester, 445.9);
    await tester.pump();

    expect(find.text('SNR: 445.9'), findsOneWidget);
  });
}
