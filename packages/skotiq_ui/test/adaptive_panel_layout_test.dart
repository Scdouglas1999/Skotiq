import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host({
  PhonePanelStrategy strategy = PhonePanelStrategy.bottomSheet,
  List<AdaptivePanel>? secondary,
}) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: AdaptivePanelLayout(
        phoneStrategy: strategy,
        primary: const ColoredBox(
          color: Color(0xFF101010),
          child: Center(child: Text('PRIMARY')),
        ),
        secondary:
            secondary ??
            const [
              AdaptivePanel(
                title: 'Controls',
                icon: Icons.tune,
                child: Center(child: Text('CONTROLS')),
              ),
            ],
      ),
    ),
  );
}

Future<void> _pumpAt(
  WidgetTester tester,
  Size size,
  Widget child, {
  TargetPlatform? platform,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  if (platform != null) debugDefaultTargetPlatformOverride = platform;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
  // Build has consumed the platform; clear before the end-of-body invariant.
  debugDefaultTargetPlatformOverride = null;
}

Finder get _resizeHandle => find.byWidgetPredicate(
  (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
);

void main() {
  group('phone portrait', () {
    final phoneSizes = <String, Size>{
      '360x640': const Size(360, 640),
      '390x844': const Size(390, 844),
    };

    for (final entry in phoneSizes.entries) {
      testWidgets('bottom-sheet collapse at ${entry.key}', (tester) async {
        await _pumpAt(tester, entry.value, _host());
        expect(tester.takeException(), isNull);

        // Primary fills the screen; controls hidden behind a handle.
        expect(find.text('PRIMARY'), findsOneWidget);
        expect(find.text('CONTROLS'), findsNothing);

        // The handle button shows the panel title; tapping opens the sheet.
        expect(find.text('Controls'), findsOneWidget);
        await tester.tap(find.text('Controls'));
        await tester.pumpAndSettle();
        expect(find.text('CONTROLS'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      // The collapsed handle must RESERVE its height: floated over the primary
      // it leaves `primary` laid out at the full viewport height and paints
      // across its last ~56dp, slicing whatever the primary anchors to its own
      // bottom edge.
      testWidgets('collapsed handle reserves space, never overlaps the '
          'primary at ${entry.key}', (tester) async {
        await _pumpAt(tester, entry.value, _host());
        expect(tester.takeException(), isNull);

        final primaryRect = tester.getRect(find.text('PRIMARY'));
        final handleRect = tester.getRect(find.text('Controls'));

        // The handle sits strictly BELOW the primary region's painted content.
        expect(
          handleRect.top,
          greaterThanOrEqualTo(primaryRect.bottom),
          reason: 'the collapsed Controls handle overlaps the primary region',
        );

        // And the primary must actually have been shortened: it cannot still
        // run to the bottom of the viewport once the handle has been reserved.
        final primaryBox = tester.getRect(
          find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == const Color(0xFF101010),
          ),
        );
        expect(
          primaryBox.bottom,
          lessThanOrEqualTo(handleRect.top),
          reason: 'the primary region still extends under the handle',
        );
        expect(primaryBox.bottom, lessThan(entry.value.height));
      });

      testWidgets('segmented collapse at ${entry.key}', (tester) async {
        await _pumpAt(
          tester,
          entry.value,
          _host(strategy: PhonePanelStrategy.segmented),
        );
        expect(tester.takeException(), isNull);

        // Primary shown by default; switching segment shows controls.
        expect(find.text('PRIMARY'), findsOneWidget);
        expect(find.text('CONTROLS'), findsNothing);

        await tester.tap(find.text('Controls'));
        await tester.pumpAndSettle();
        expect(find.text('CONTROLS'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('phone landscape', () {
    testWidgets('shows side-by-side split when wide enough (844x390)', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(844, 390), _host());
      expect(tester.takeException(), isNull);
      // Both visible at once — no collapse.
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);
    });

    testWidgets('falls back to collapse when too narrow (640x360)', (
      tester,
    ) async {
      // 640 < landscapeSplitMinWidth (560)? 640 >= 560 so it WILL split.
      await _pumpAt(tester, const Size(640, 360), _host());
      expect(tester.takeException(), isNull);
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);
    });
  });

  group('phone device in landscape (wide viewport)', () {
    // A phone in landscape reports a desktop-class WIDTH, so a width-only
    // check takes the desktop resizable split. On a mobile OS the device is
    // still a phone and must use the phone split — no desktop chrome.
    testWidgets('android phone at 1100x480 uses the phone split, not desktop', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        const Size(1100, 480),
        _host(),
        platform: TargetPlatform.android,
      );
      expect(tester.takeException(), isNull);
      // Side-by-side phone split: both visible...
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);
      // ...but NOT the desktop resizable split (no drag handle).
      expect(_resizeHandle, findsNothing);
    });

    testWidgets(
      'android phone at 932x430 (Pro Max landscape) is a phone split',
      (tester) async {
        await _pumpAt(
          tester,
          const Size(932, 430),
          _host(),
          platform: TargetPlatform.iOS,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('PRIMARY'), findsOneWidget);
        expect(find.text('CONTROLS'), findsOneWidget);
        expect(_resizeHandle, findsNothing);
      },
    );
  });

  group('tablet / desktop', () {
    testWidgets('fixed split in the tablet band (700x1000)', (tester) async {
      await _pumpAt(tester, const Size(700, 1000), _host());
      expect(tester.takeException(), isNull);
      // Side-by-side: both present, no sheet handle button duplication.
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);
      expect(_resizeHandle, findsNothing);
    });

    // 800 px sits above BreakpointTokens.breakpointTablet (768), which is what
    // `isAtLeastDesktop` dispatches on — so this is the resizable split, not
    // the fixed one. Pinned because the doc used to claim the fixed branch ran
    // up to 1024 and nothing tested the difference.
    testWidgets('800x1000 is the resizable split, not the fixed one', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(800, 1000), _host());
      expect(tester.takeException(), isNull);
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);
      expect(_resizeHandle, findsOneWidget);
    });

    testWidgets('resizable split on desktop (1400x900)', (tester) async {
      await _pumpAt(tester, const Size(1400, 900), _host());
      expect(tester.takeException(), isNull);
      expect(find.text('PRIMARY'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);

      // A draggable divider exists (MouseRegion with resizeColumn cursor).
      final handle = find.byWidgetPredicate(
        (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
      );
      expect(handle, findsOneWidget);

      // Dragging the handle does not throw.
      await tester.drag(handle, const Offset(-80, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('two secondary panels segment correctly on phone', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(390, 844),
      _host(
        strategy: PhonePanelStrategy.segmented,
        secondary: const [
          AdaptivePanel(
            title: 'Tune',
            child: Center(child: Text('TUNE')),
          ),
          AdaptivePanel(
            title: 'Stats',
            child: Center(child: Text('STATS')),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Stats'));
    await tester.pumpAndSettle();
    expect(find.text('STATS'), findsOneWidget);
  });
}
