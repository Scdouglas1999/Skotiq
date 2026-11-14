// The guide target display must not mark a reading it does not have.
//
// Coalescing an absent error to 0 on the way into the painter pins a red × at
// 0,0 in the Target Display while the guider is Stopped with no data at all, so
// "nothing measured" renders as "perfectly guided". Same shape as the polar
// bullseye.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_app/screens/guiding/widgets/guide_target_display.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a guider with no measurement marks nothing', (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: [],
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final display = tester.widget<GuideTargetDisplay>(
      find.byType(GuideTargetDisplay),
    );
    expect(
      display.showCurrentError,
      isFalse,
      reason: 'the guider is stopped with no error history to mark',
    );
  });
}
