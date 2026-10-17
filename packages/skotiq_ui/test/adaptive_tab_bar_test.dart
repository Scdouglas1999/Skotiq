import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _tabs = [
  AdaptiveTab(label: 'Session', icon: Icons.bar_chart),
  AdaptiveTab(label: 'History', icon: Icons.history),
  AdaptiveTab(label: 'Projects', icon: Icons.folder),
  AdaptiveTab(label: 'Equipment', icon: Icons.settings),
  AdaptiveTab(label: 'Science', icon: Icons.science),
  AdaptiveTab(label: 'Diagnostics', icon: Icons.bug_report),
  AdaptiveTab(label: 'Telemetry', icon: Icons.timeline),
  AdaptiveTab(label: 'Calibration', icon: Icons.tune),
];

Widget _host({int selected = 0, ValueChanged<int>? onSelected}) {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: SizedBox(
        height: 48,
        child: AdaptiveTabBar(
          tabs: _tabs,
          selectedIndex: selected,
          onSelected: onSelected ?? (_) {},
        ),
      ),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(child);
  await tester.pumpAndSettle();
}

void main() {
  final sizes = <String, Size>{
    '360x640 portrait': const Size(360, 640),
    '640x360 landscape': const Size(640, 360),
    '390x844 portrait': const Size(390, 844),
    '844x390 landscape': const Size(844, 390),
  };

  for (final entry in sizes.entries) {
    testWidgets('no overflow and scrolls at ${entry.key}', (tester) async {
      await _pumpAt(tester, entry.value, _host());

      // No RenderFlex overflow thrown.
      expect(tester.takeException(), isNull);

      // The bar is horizontally scrollable when tabs do not fit.
      final scrollable = find.descendant(
        of: find.byType(AdaptiveTabBar),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scrollable, findsOneWidget);

      // Every tab is built (icons always present even when labels collapse).
      expect(find.byIcon(Icons.bar_chart), findsOneWidget);
      expect(find.byIcon(Icons.tune), findsOneWidget);

      // Dragging the bar does not throw.
      await tester.drag(scrollable, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tapping a tab reports its index', (tester) async {
    int? tapped;
    // Wide viewport so labels are shown (not collapsed).
    await _pumpAt(
      tester,
      const Size(1000, 800),
      _host(onSelected: (i) => tapped = i),
    );
    await tester.tap(find.text('History'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('tapping by icon works on a compact phone', (tester) async {
    int? tapped;
    await _pumpAt(
      tester,
      const Size(360, 640),
      _host(onSelected: (i) => tapped = i),
    );
    // Labels collapse on compact phones; the icon is still tappable.
    expect(find.text('History'), findsNothing);
    await tester.tap(find.byIcon(Icons.history));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('selecting later tab keeps it built', (tester) async {
    await _pumpAt(tester, const Size(360, 640), _host(selected: 7));
    expect(tester.takeException(), isNull);
    // The selected far tab is in the tree even when scrolled out of view.
    expect(find.byIcon(Icons.tune), findsOneWidget);
  });

  testWidgets('labels show, not collapse, on a wide viewport', (tester) async {
    await _pumpAt(tester, const Size(1200, 800), _host());
    expect(find.text('Session'), findsOneWidget);
    expect(find.text('Calibration'), findsOneWidget);
  });

  group('overflow is discoverable and reachable with a mouse', () {
    // A clipped strip used to look exactly like a strip that fits: no fade, no
    // chevron, no scrollbar. Plain vertical wheel did nothing and mouse DRAG is
    // excluded from Flutter's dragDevices, so the only recovery was shift+wheel
    // — which nothing on screen advertised.
    Finder chevrons() =>
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'More tabs');

    testWidgets('a clipped strip shows a scroll affordance', (tester) async {
      await _pumpAt(tester, const Size(600, 300), _host());
      expect(
        chevrons(),
        findsOneWidget,
        reason: 'Tabs overflow at 600px, so the trailing edge must say so.',
      );
    });

    testWidgets('a strip that fits shows no affordance', (tester) async {
      await _pumpAt(tester, const Size(2200, 300), _host());
      expect(chevrons(), findsNothing);
    });

    testWidgets('vertical mouse wheel scrolls the horizontal strip', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(600, 300), _host());
      final scrollable = find.descendant(
        of: find.byType(AdaptiveTabBar),
        matching: find.byType(SingleChildScrollView),
      );
      final controller = tester
          .widget<SingleChildScrollView>(scrollable)
          .controller!;
      expect(controller.offset, 0);

      final center = tester.getCenter(scrollable);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 160)));
      await tester.pumpAndSettle();

      expect(
        controller.offset,
        greaterThan(0),
        reason:
            'A plain vertical wheel must move a horizontal tab strip; it '
            'was previously a no-op with no other mouse-only recovery.',
      );
    });

    testWidgets('tapping the chevron scrolls further tabs into view', (
      tester,
    ) async {
      await _pumpAt(tester, const Size(600, 300), _host());
      final scrollable = find.descendant(
        of: find.byType(AdaptiveTabBar),
        matching: find.byType(SingleChildScrollView),
      );
      final controller = tester
          .widget<SingleChildScrollView>(scrollable)
          .controller!;

      await tester.tap(chevrons());
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));

      // Now that the strip is scrolled, a LEADING affordance appears too.
      expect(chevrons(), findsNWidgets(2));
    });

    // Chevrons `Positioned` over the strip paint on top of the tab labels: at
    // 900 px the right one covers Science and it renders as `S › ce`; after a
    // nudge the left one covers History (`Hi ‹ y`) and the right clips
    // Diagnostics. A hint must not eat the label it is hinting about, so the
    // geometry is pinned: no chevron rect may intersect a tab label rect.
    testWidgets('a chevron never paints over a tab label', (tester) async {
      await _pumpAt(tester, const Size(900, 760), _host());
      expect(chevrons(), findsWidgets);

      void assertNoOverlap() {
        final chevronRects = [
          for (var i = 0; i < chevrons().evaluate().length; i++)
            tester.getRect(chevrons().at(i)),
        ];
        expect(chevronRects, isNotEmpty);
        // What the user actually sees of a label is the part inside the
        // strip's viewport; anything past it is clipped by the scroll (and
        // reachable by scrolling), which is a different thing from being
        // painted over.
        final viewport = tester.getRect(
          find.descendant(
            of: find.byType(AdaptiveTabBar),
            matching: find.byType(SingleChildScrollView),
          ),
        );
        for (final label in _tabs.map((t) => t.label)) {
          final finder = find.text(label);
          if (finder.evaluate().isEmpty) continue;
          final visible = tester.getRect(finder).intersect(viewport);
          if (visible.isEmpty || visible.width <= 0) continue;
          for (final chevron in chevronRects) {
            expect(
              chevron.overlaps(visible),
              isFalse,
              reason:
                  '"$label" (visible $visible) is painted under a chevron '
                  '($chevron)',
            );
          }
        }
      }

      assertNoOverlap();

      // And after scrolling, when BOTH chevrons are up.
      await tester.tap(chevrons().first);
      await tester.pumpAndSettle();
      expect(chevrons(), findsNWidgets(2));
      assertNoOverlap();
    });
  });

  testWidgets('labels collapse inside a narrow pane on a wide viewport', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(1000, 800),
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 320, height: 48, child: _host()),
          ),
        ),
      ),
    );

    expect(find.text('Session'), findsNothing);
    expect(find.byIcon(Icons.bar_chart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The bar is almost always a passenger inside something else that scrolls —
  // a page pager, a settings list. Keeping the selected tab visible is the
  // bar's own business and must not move its host: `Scrollable.ensureVisible`
  // walks EVERY ancestor Scrollable, which made the sequencer's whole screen
  // lurch sideways when the inspector's Activity tab was clicked.
  testWidgets('selecting a clipped tab does not scroll the host', (
    tester,
  ) async {
    final hostController = ScrollController();
    addTearDown(hostController.dispose);
    var selected = 0;

    await _pumpAt(
      tester,
      const Size(420, 600),
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            controller: hostController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              // Wider than the 420px viewport, so the host has somewhere to
              // scroll to and a bug there is observable.
              width: 900,
              child: StatefulBuilder(
                builder: (context, setState) => SizedBox(
                  height: 48,
                  child: AdaptiveTabBar(
                    tabs: _tabs,
                    selectedIndex: selected,
                    onSelected: (i) => setState(() => selected = i),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(hostController.offset, 0);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(selected, 1, reason: 'the tap has to have selected the tab');
    expect(
      hostController.offset,
      0,
      reason: 'the host scrolled because the bar revealed its own tab',
    );
  });
}
