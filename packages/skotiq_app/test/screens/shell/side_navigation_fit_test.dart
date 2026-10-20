// The expanded rail at short windows: every destination is whole and clear
// of the collapse toggle. At 1443 x 760 the full-size rail did not fit and
// Analytics sat half hidden behind "Collapse navigation"; the rail now
// compacts first and only scrolls when even that cannot fit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/shell/shell_navigation.dart';
import 'package:skotiq_app/screens/shell/widgets/side_navigation.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../night_control/night_screen_test_support.dart';

void main() {
  for (final size in const <Size>[Size(1443, 760), Size(1536, 864)]) {
    testWidgets(
        'rail open at ${size.width.toInt()} x ${size.height.toInt()}: '
        'every item is whole and clear of the toggle', (tester) async {
      await pumpNightShell(
        tester,
        overrides: nightScreenOverrides(NightScreenState.running),
        railCollapsed: false,
        size: size,
      );
      expect(tester.takeException(), isNull);

      final list = find.byKey(const ValueKey<String>('sideNav.list'));
      final viewport = tester.getRect(list);
      final toggle =
          tester.getRect(find.byKey(const ValueKey<String>('sideNav.toggle')));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      );
      expect(scrollable.position.maxScrollExtent, 0,
          reason: 'the rail should fit without scrolling');

      final items = find.descendant(of: list, matching: find.byType(NavItem));
      expect(items, findsNWidgets(ShellNavigation.primaryDestinations.length));
      for (final element in items.evaluate()) {
        final item = element.widget as NavItem;
        final rect = tester.getRect(find.byWidget(item));
        expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.5),
            reason: '${item.label} starts above the list');
        expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
            reason: '${item.label} is cut off by the list edge');
        expect(rect.bottom, lessThanOrEqualTo(toggle.top + 0.5),
            reason: '${item.label} runs under the collapse toggle');
      }
      expect(find.text('Analytics'), findsOneWidget);
      await unmountNightShell(tester);
    });
  }

  test('the rail compacts only when the full-size rail does not fit', () {
    final entries = <SideNavEntry>[
      const SideNavGroupHeading('Observe'),
      for (var i = 0; i < 4; i++)
        SideNavTab(icon: Icons.circle, label: '$i', index: i),
      const SideNavGroupHeading('Prepare'),
      for (var i = 4; i < 7; i++)
        SideNavTab(icon: Icons.circle, label: '$i', index: i),
      const SideNavGroupHeading('Review'),
      for (var i = 7; i < 9; i++)
        SideNavTab(icon: Icons.circle, label: '$i', index: i),
    ];
    double height({required bool compact}) => SideNavigation.contentHeight(
          entries: entries,
          isExpanded: true,
          compact: compact,
          headingTextHeight: 14,
        );
    expect(height(compact: true), lessThan(height(compact: false)));
    // Nine items: 9 x (40 + 2), headings 14 + 4 each plus 10 above the last
    // two, then the list padding, the 40 px toggle and its padding.
    expect(height(compact: false), 9 * 42 + 3 * 18 + 2 * 10 + 8 + 40 + 8);
  });
}
