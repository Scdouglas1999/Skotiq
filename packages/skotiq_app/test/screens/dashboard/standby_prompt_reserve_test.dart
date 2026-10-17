// The prompt reserve has to land in the scroll view the STANDBY dashboard
// actually uses.
//
// `dashboard_screen.dart` renders `Expanded(child: CockpitStandby(...))` here,
// and CockpitStandby owns its OWN SingleChildScrollView. `DashboardScrollView`
// is the other branch — the zone cockpit shown when a run is live — so a
// reserve added there does nothing on this layout: scrolled to the HARD bottom
// the floating "Build tonight's plan?" prompt still sits at y 537-645 over the
// Moon card's Moonrise row at y~634, label visible and value hidden, and
// dismissing it at the identical offset reveals "08:12" at exactly that y with
// nothing moved.
//
// So this measures the max scroll extent with the prompt up MINUS the extent
// without it. If the prompt costs the layout nothing, that difference is zero,
// which is the defect.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_standby.dart';
import 'package:skotiq_app/screens/dashboard/widgets/smart_night_prompt_card.dart'
    show floatingPromptOwnersProvider, kFloatingPromptReservedHeight;
import 'package:skotiq_ui/skotiq_ui.dart';

Future<ScrollPosition> _pumpStandby(
  WidgetTester tester, {
  required bool promptShowing,
}) async {
  tester.view.devicePixelRatio = 1;
  // Narrower than CockpitStandby's 900 px live-astronomy breakpoint: above it
  // the briefing mounts the planetarium's 1 s observation clock, which outlives
  // the tree and trips the binding's timer check. The reserve under test is not
  // width-dependent — it is the scroll view's bottom padding.
  // Short enough that the briefing overflows in BOTH cases, so the delta is
  // the reserve itself rather than whatever slack a tall window happened to
  // have.
  tester.view.physicalSize = const Size(860, 400);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  await tester.pumpWidget(
    ProviderScope(
      // A fresh scope per case. Re-pumping one whose `overrideWith` changed
      // keeps the provider state the first pump created, so without a new key
      // the second case silently measures the first case's container.
      key: ValueKey(promptShowing),
      overrides: [
        floatingPromptOwnersProvider.overrideWith(
          (_) => promptShowing
              ? {'test-card': kFloatingPromptReservedHeight}
              : const <String, double>{},
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: CockpitStandby(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  return tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CockpitStandby),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the standby briefing pays for the floating prompt band', (
    tester,
  ) async {
    final without =
        (await _pumpStandby(tester, promptShowing: false)).maxScrollExtent;
    final with_ =
        (await _pumpStandby(tester, promptShowing: true)).maxScrollExtent;

    expect(
      with_ - without,
      greaterThanOrEqualTo(kFloatingPromptReservedHeight),
      reason: 'max scroll must differ with and without the prompt, so the last '
          'card can be scrolled out from under it',
    );
  });

  testWidgets('and the briefing keeps its own scroll view', (tester) async {
    await _pumpStandby(tester, promptShowing: true);
    final scrollView = tester.widget<SingleChildScrollView>(
      find
          .descendant(
            of: find.byType(CockpitStandby),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );
    expect(
      (scrollView.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(kFloatingPromptReservedHeight),
    );
  });
}
