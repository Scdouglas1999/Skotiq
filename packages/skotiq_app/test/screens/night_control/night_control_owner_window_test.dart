// Tonight at the owner's window: a 1920 x 1080 panel at 125 % gives a
// 1536 x 864 logical window. The real shell takes its rail, title bar and
// status bar out of that, leaving Tonight about 1316 px with the rail open
// and 1480 px with it closed; both are three-column widths.
//
// Every board state (Ready, Running, a manual autofocus) is pumped with each
// panel tab selected, rail open and closed, and must lay out without an
// exception (an overflow among them) and with the whole action bar on
// screen. The shell's own run bar and autofocus overlay stand down here.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/manual_action_bar.dart';
import 'package:skotiq_app/screens/night_control/header/night_header_bar.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_layout.dart';
import 'package:skotiq_app/screens/night_control/night_control_screen.dart';
import 'package:skotiq_app/screens/night_control/panel/night_right_panel.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_app/widgets/autofocus_progress_overlay.dart';
import 'package:skotiq_app/widgets/running_sequence_mini_bar.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';
import 'night_screen_test_support.dart';

const _tabLabels = <NightPanelTab, String>{
  NightPanelTab.overview: 'Overview',
  NightPanelTab.camera: 'Camera',
  NightPanelTab.focus: 'Focus',
  NightPanelTab.mount: 'Mount',
  NightPanelTab.guide: 'Guide',
  NightPanelTab.solve: 'Solve',
};

void _expectWholeActionBar(WidgetTester tester, Rect screen) {
  final bar = find.byType(ManualActionBar);
  expect(bar, findsOneWidget);
  final barRect = tester.getRect(bar);
  expect(barRect.left, greaterThanOrEqualTo(screen.left));
  expect(barRect.right, lessThanOrEqualTo(screen.right + 0.5));
  // The buttons sit in a horizontal scroller for narrow windows; at the
  // owner's width every one of them fits without scrolling.
  final scrollable = tester.state<ScrollableState>(
    find.descendant(of: bar, matching: find.byType(Scrollable)).first,
  );
  expect(scrollable.position.maxScrollExtent, 0,
      reason: 'the action bar needs to scroll to show every button');
  final buttons = find.descendant(of: bar, matching: find.byType(InkWell));
  expect(buttons, findsWidgets);
  for (final element in buttons.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.right, lessThanOrEqualTo(barRect.right + 0.5),
        reason: 'an action-bar button runs off the bar');
  }
}

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  for (final collapsed in <bool>[false, true]) {
    final rail = collapsed ? 'rail closed' : 'rail open';
    for (final state in NightScreenState.values) {
      testWidgets('${state.name}, every tab, $rail', (tester) async {
        for (final tab in NightPanelTab.values) {
          await pumpNightShell(
            tester,
            overrides: nightScreenOverrides(state, tab: tab),
            railCollapsed: collapsed,
          );
          expect(tester.takeException(), isNull,
              reason: '${state.name} / ${tab.name} / $rail');

          final screen = tester.getRect(find.byType(NightControlScreen));
          final density = tester.widget<NightControlDensity>(
            find.byType(NightControlDensity),
          );
          expect(density.mode, NightControlMode.threeColumn,
              reason: 'Tonight gets ${screen.width} px');
          expect(screen.width, greaterThanOrEqualTo(1300));
          // Non-vacuous: the rail setting reached the shell.
          expect(screen.width, collapsed ? greaterThan(1400) : lessThan(1400));
          expect(screen.right, lessThanOrEqualTo(kOwnerWindow.width));

          expect(find.byType(NightHeaderBar), findsOneWidget);
          _expectWholeActionBar(tester, screen);

          // The selected tab is the one on show.
          final panel = find.byType(NightRightPanel);
          final strip = find.descendant(
            of: panel,
            matching: find.byType(PanelTabStrip),
          );
          expect(
            tester.widget<PanelTabStrip>(strip).selectedIndex,
            tab.index,
          );
          expect(
            find.descendant(of: strip, matching: find.text(_tabLabels[tab]!)),
            findsOneWidget,
          );

          // The header carries the run controls; the shell's bar stands down.
          expect(
            tester.getSize(find.byType(RunningSequenceMiniBar)).height,
            0,
          );
          expect(find.byType(AutofocusProgressOverlay), findsNothing);

          await unmountNightShell(tester);
        }
      }, timeout: const Timeout(Duration(minutes: 3)));
    }
  }

  testWidgets('the screen keeps the run alerts and their bridge alive',
      (tester) async {
    await pumpNightShell(
      tester,
      overrides: nightScreenOverrides(NightScreenState.running),
      railCollapsed: false,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NightControlScreen)),
    );
    expect(container.exists(runDashboardCriticalEventsBridgeProvider), isTrue,
        reason: 'critical events reach toasts and phones only while watched');

    container.read(runDashboardCriticalEventsProvider.notifier).add(
          RunDashboardEvent(
            eventId: BigInt.one,
            time: DateTime.utc(2026, 10, 18, 3, 52),
            severity: RunDashboardEventSeverity.critical,
            category: 'Guiding',
            title: 'Guide star lost',
            message: 'PHD2 lost the guide star for 30 s',
            isCritical: true,
          ),
        );
    await tester.pump();
    expect(find.textContaining('Guide star lost'), findsWidgets);
    expect(tester.takeException(), isNull);
    await unmountNightShell(tester);
  });
}
