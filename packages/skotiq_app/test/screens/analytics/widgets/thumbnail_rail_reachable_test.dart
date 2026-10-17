// The Captured Images rail has to be usable with the mouse an operator has.
//
// Observed: with 16 frames in the session only 12 thumbnails fit. Pointing at
// the rail and turning the wheel scrolled the PAGE; only shift+wheel moved the
// rail, and nothing on screen said so. There was no scrollbar either, so
// "there are more frames" was invisible. And a left click on a thumbnail — the
// gesture everyone tries first — did nothing anywhere in Analytics:
// ImageThumbnailStrip took an onImageTap callback that no caller in the app
// ever passed.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/frame_detail_dialog.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_thumbnail_strip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

DbCapturedImage _frame(int id) => DbCapturedImage(
      id: id,
      filePath: '/tmp/frame_$id.fits',
      fileName: 'frame_$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 1, 22, id),
      createdAt: DateTime.utc(2026, 8, 1, 22, id),
      isAccepted: true,
      isPlateSolved: false,
      hfr: 2.1,
      starCount: 800,
      filter: 'L',
    );

Widget _strip(List<DbCapturedImage> images) => ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          // Narrower than 16 x 108px of thumbnails, so the rail really is
          // clipped and really does need to scroll.
          body:
              SizedBox(width: 400, child: ImageThumbnailStrip(images: images)),
        ),
      ),
    );

/// The first thumbnail tile — NOT the quality filter chips above the rail,
/// which are InkWells too.
Finder _thumbnail(WidgetTester tester) => find
    .descendant(of: find.byType(Scrollbar), matching: find.byType(InkWell))
    .first;

ScrollableState _railScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(Scrollbar),
        matching: find.byType(Scrollable),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a plain vertical wheel over the rail scrolls the rail',
      (tester) async {
    final images = List.generate(16, (i) => _frame(i + 1));
    await tester.pumpWidget(_strip(images));
    await tester.pump();

    final scrollable = _railScrollable(tester);
    expect(scrollable.position.pixels, 0);
    expect(
      scrollable.position.maxScrollExtent,
      greaterThan(0),
      reason: '16 frames at 108px do not fit in 400px; the rail must scroll',
    );

    final railCentre = tester.getCenter(find.byType(Scrollbar));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(railCentre));
    // dy only — no shift, no horizontal component: an ordinary wheel notch.
    await tester.sendEventToBinding(
      pointer.scroll(const Offset(0, 220)),
    );
    await tester.pump();

    expect(
      _railScrollable(tester).position.pixels,
      greaterThan(0),
      reason: 'a vertical wheel notch has to move a horizontal rail on desktop',
    );
  });

  testWidgets('the rail carries a permanently visible scrollbar',
      (tester) async {
    await tester.pumpWidget(_strip(List.generate(16, (i) => _frame(i + 1))));
    await tester.pump();

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(
      scrollbar.thumbVisibility,
      isTrue,
      reason: 'an overlay-only bar leaves "there are more frames" invisible',
    );
  });

  testWidgets('tapping a thumbnail opens the frame inspector', (tester) async {
    await tester.pumpWidget(_strip([_frame(1)]));
    await tester.pump();

    expect(find.byType(FrameDetailDialog), findsNothing);
    await tester.tap(_thumbnail(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(FrameDetailDialog),
      findsOneWidget,
      reason: 'the rail is a gallery; a click on a frame must open it',
    );
    // And it reports the frame, not a generic sheet.
    expect(find.text('frame_1.fits'), findsWidgets);
  });

  testWidgets('the wheel notch that moves the rail does not also move the page',
      (tester) async {
    // The rail lives inside session_tab's SingleChildScrollView. A Listener
    // callback does not consume a pointer signal, so translating the notch
    // without claiming it left BOTH scrollers moving 220px: the rail slid
    // sideways while the page carried it off screen.
    final page = ScrollController();
    addTearDown(page.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [inMemoryDatabaseOverride()],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: SingleChildScrollView(
                controller: page,
                child: Column(
                  children: [
                    const SizedBox(height: 100),
                    ImageThumbnailStrip(
                      images: List.generate(16, (i) => _frame(i + 1)),
                    ),
                    const SizedBox(height: 1200),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(Scrollbar))));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 220)));
    await tester.pump();

    expect(_railScrollable(tester).position.pixels, greaterThan(0));
    expect(
      page.offset,
      0,
      reason: 'the notch the rail consumed must not also scroll the page',
    );
  });

  testWidgets('shift+wheel moves the rail once, not twice', (tester) async {
    // The rail's own Scrollable already flips axes under shift. Translating
    // the notch a second time in the Listener moved it 200px for a 100px
    // notch.
    await tester.pumpWidget(_strip(List.generate(16, (i) => _frame(i + 1))));
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    addTearDown(() => tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft));
    await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(Scrollbar))));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();

    expect(
      _railScrollable(tester).position.pixels,
      100,
      reason: 'one notch, one scroll — not one from the Scrollable and one '
          'from the wheel translator',
    );
  });

  testWidgets('a caller-supplied handler still wins over the inspector',
      (tester) async {
    DbCapturedImage? tapped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [inMemoryDatabaseOverride()],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ImageThumbnailStrip(
              images: [_frame(7)],
              onImageTap: (image) => tapped = image,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(_thumbnail(tester));
    await tester.pump();

    expect(tapped?.id, 7);
    expect(find.byType(FrameDetailDialog), findsNothing);
  });
}
