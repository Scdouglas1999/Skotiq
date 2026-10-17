// The frame-quality badge (GOOD / NEEDS REVIEW / POOR) must paint ON TOP of the
// thumbnail.
//
// Observed defect: the badge was the FIRST child of the tile's Stack, so every
// thumbnail that actually loaded (Image.memory, BoxFit.cover, infinite
// width/height) painted over it. The chip was therefore visible only on frames
// whose image FAILED to load — the summary said "Needs Review: 18" and the user
// could not see which 18. Stack children paint in list order, so this test pins
// the badge's position after the thumbnail.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_thumbnail_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

DbCapturedImage _softFrame() => DbCapturedImage(
      id: 11,
      filePath: '/lights/soft-11.fits',
      fileName: 'soft-11.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      // Soft stars + a low star count: the assessor grades this "needs review",
      // which is exactly the badge the cull workflow depends on seeing.
      hfr: 4.6,
      starCount: 40,
      capturedAt: DateTime.utc(2026, 7, 28),
      createdAt: DateTime.utc(2026, 7, 28),
      isAccepted: true,
      isPlateSolved: false,
    );

/// The tile's Stack: the one holding both the thumbnail [Center] and the
/// quality badge (a [Positioned] wrapping a [Tooltip]).
Stack _tileStack(WidgetTester tester) {
  for (final stack in tester.widgetList<Stack>(find.byType(Stack))) {
    final hasCenter = stack.children.any((c) => c is Center);
    final hasBadge = stack.children.any(
      (c) => c is Positioned && c.child is Tooltip,
    );
    if (hasCenter && hasBadge) return stack;
  }
  fail('No thumbnail tile Stack with a quality badge was built');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quality badge is added after the thumbnail so it paints on top',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ImageThumbnailStrip(images: [_softFrame()]),
          ),
        ),
      ),
    );
    await tester.pump();

    // The summary claims a frame needs review…
    expect(find.textContaining('Needs Review'), findsWidgets);

    final children = _tileStack(tester).children;
    final centerIndex = children.indexWhere((c) => c is Center);
    final badgeIndex = children.indexWhere(
      (c) => c is Positioned && c.child is Tooltip,
    );
    expect(centerIndex, isNonNegative);
    expect(badgeIndex, isNonNegative);

    // …and the chip that says WHICH frame paints over the image, not under it.
    expect(
      badgeIndex,
      greaterThan(centerIndex),
      reason: 'the quality badge must come after the thumbnail in the Stack, '
          'otherwise a loaded thumbnail covers it',
    );
  });
}
