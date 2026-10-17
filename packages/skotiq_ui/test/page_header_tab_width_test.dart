// The page header's tab strip must get the width the title and the actions do
// not use.
//
// It used to be a `Flexible` followed by a `Spacer`, which made the title
// block, the strip and the spacer three flex children of equal weight. On a
// 1600px window the strip was handed about a third of the ~1180px going spare
// — measured at ~330px on a built bundle — so the Plan screen's six tabs read
// "Tonight · Projects · Schedule · Framir…" behind a scroll arrow, while every
// screen mockup shows the whole strip. This is the check against that.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Plan screen's six tabs — the longest strip any screen asks the header
/// for, and the one the defect was found on.
const _planTabs = <AdaptiveTab>[
  AdaptiveTab(label: 'Tonight', icon: Icons.nightlight),
  AdaptiveTab(label: 'Projects', icon: Icons.folder),
  AdaptiveTab(label: 'Schedule', icon: Icons.calendar_today),
  AdaptiveTab(label: 'Framing', icon: Icons.crop),
  AdaptiveTab(label: 'Planetarium', icon: Icons.public),
  AdaptiveTab(label: 'Your sky', icon: Icons.blur_on),
];

Widget _host() {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: PageHeader(
        icon: Icons.explore,
        title: 'Plan',
        tabs: AdaptiveTabBar(
          tabs: _planTabs,
          selectedIndex: 0,
          onSelected: (_) {},
          horizontalPadding: 0,
        ),
        // The two chips the Plan header carries, at about the width their real
        // copy takes ("Moon 43%", "Dark 20:54 – 04:51").
        actions: const [
          SkotiqChip(label: 'Moon 43%'),
          SkotiqChip(label: 'Dark 20:54 – 04:51'),
        ],
      ),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(_host());
  await tester.pump();
}

void main() {
  _NoTabs.register();
  testWidgets('at 1600px every tab label is rendered and nothing overflows', (
    tester,
  ) async {
    await _pumpAt(tester, const Size(1600, 900));

    for (final tab in _planTabs) {
      expect(
        find.text(tab.label),
        findsOneWidget,
        reason: '"${tab.label}" must be on screen at the mockup width',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the strip gets the width the title and actions leave', (
    tester,
  ) async {
    await _pumpAt(tester, const Size(1600, 900));

    final strip = tester.getRect(find.byType(AdaptiveTabBar));
    final title = tester.getRect(find.text('Plan'));

    // The old layout handed the strip about a third of the free width (~330px
    // of ~1180). Half is a generous floor that the defect could not have
    // reached and the fix clears comfortably.
    expect(
      strip.width,
      greaterThan(600),
      reason: 'the tab strip must take the free width, not a flex share of it',
    );
    // And it starts after the title, not on top of it.
    expect(strip.left, greaterThan(title.right));
  });

  testWidgets('the six labels still fit at 1100px', (tester) async {
    // Above the shell layout breakpoint the header keeps title, tabs and
    // actions on ONE row, so this is the narrowest desktop the strip has to
    // hold six names at.
    await _pumpAt(tester, const Size(1100, 900));

    for (final tab in _planTabs) {
      expect(find.text(tab.label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'below the breakpoint the strip moves to its own full-width row',
    (tester) async {
      await _pumpAt(
        tester,
        Size(ShellChromeMetrics.shellLayoutBreakpoint - 100, 900),
      );

      // Its own row means it is no longer competing with the title and the
      // actions, so it spans the header.
      final strip = tester.getRect(find.byType(AdaptiveTabBar));
      expect(strip.width, ShellChromeMetrics.shellLayoutBreakpoint - 100);
      expect(tester.takeException(), isNull);
    },
  );
}

// A header WITHOUT tabs (Onboarding, Settings, Tonight) must still put its
// actions at the right edge. A Flexible title used to split the free space with
// the trailing Spacer and, being a loose fit, leave its unused share after the
// actions — they sat mid-row on every tab-less screen.
Widget _hostNoTabs() {
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      body: PageHeader(
        icon: Icons.settings,
        title: 'Settings',
        actions: const [SkotiqChip(label: 'Backup', key: Key('trail'))],
      ),
    ),
  );
}

class _NoTabs {
  static void register() {
    testWidgets('without tabs the actions sit at the right edge', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1600, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(_hostNoTabs());
      await tester.pump();
      final chip = tester.getRect(find.byKey(const Key('trail')));
      // 24 px gutter: the chip's right edge is within one gutter of the window.
      expect(chip.right, greaterThan(1600 - 24 - 2));
      expect(tester.takeException(), isNull);
    });

    // A 360 px phone header carrying a long title and four icon actions: the
    // title must give way (ellipsize) before a single action leaves the row.
    // A fixed half-width title cap once pushed the actions 62 px past the
    // right edge on Imaging, Guiding, Weather and Plan.
    testWidgets('on a phone the title yields to the actions', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: PageHeader(
              icon: Icons.camera_alt,
              title: 'Imaging with a deliberately long title',
              actions: [
                for (var i = 0; i < 4; i++)
                  SkotiqIconButton(
                    key: Key("a$i"),
                    icon: Icons.settings,
                    tooltip: 'Action $i',
                    onPressed: () {},
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final last = tester.getRect(find.byKey(const Key('a3')));
      expect(last.right, lessThanOrEqualTo(360 - 24 + 1));
      expect(last.right, greaterThan(360 - 24 - 2));
      final title = tester.getRect(
        find.text('Imaging with a deliberately long title'),
      );
      expect(
        title.right,
        lessThan(tester.getRect(find.byKey(const Key('a0'))).left),
      );
    });
  }
}
