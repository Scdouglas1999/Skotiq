// A locked rung has to offer the thing it asks for.
//
// Observed: rung 3's sheet said "Track a star ... to start collecting points"
// and rung 5's said to record photometry before exporting, and each offered
// only Close and "Got it". Neither carried a control that did the named thing,
// so the guided on-ramp ended by telling the user to go find the control
// themselves.
//
// Second pass: the unlock button existed but fired `onJumpToPhotometry`, which
// on the Science tab's populated branch merely scrolls to the PHOTOMETRY
// section — charts and export buttons. That section cannot pick a star (rung
// 2's CTA was moved off it for that exact reason), so a locked "Build a light
// curve" rung sent the operator to an empty Differential Photometry card: the
// dead end relocated, not removed. The unlock has to go to the Science HUD,
// where the star is chosen and the points accumulate.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_onboarding/science_ladder_card.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _card({
  required bool hasExportableData,
  VoidCallback? onJumpToPhotometry,
  VoidCallback? onPickTarget,
}) =>
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: ScienceLadderCard(
            hasCalibration: false,
            hasTarget: false,
            photometryLive: false,
            lightCurvePoints: 0,
            hasPeriodResult: false,
            hasExportableData: hasExportableData,
            onJumpToPhotometry: onJumpToPhotometry ?? () {},
            onRunCalibration: () {},
            onPickTarget: onPickTarget ?? () {},
            onOpenExport: () {},
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a locked rung offers the way to satisfy its prerequisite',
      (tester) async {
    var toHud = 0;
    var scrolledToCharts = 0;
    await tester.pumpWidget(
      _card(
        hasExportableData: false,
        onPickTarget: () => toHud++,
        onJumpToPhotometry: () => scrolledToCharts++,
      ),
    );
    await tester.pump();

    // Rung 3 "Build a light curve" is locked with no points and no live run.
    await tester.tap(find.text('Build a light curve'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Track a star'), findsWidgets);
    expect(find.text('Got it'), findsOneWidget);
    final unlock = find.text('Open Science HUD');
    expect(
      unlock,
      findsOneWidget,
      reason: 'the sheet names a precondition; it has to offer the control',
    );

    await tester.tap(unlock);
    await tester.pumpAndSettle();

    expect(
      toHud,
      1,
      reason: 'the button has to reach the place a star is actually tracked',
    );
    expect(
      scrolledToCharts,
      0,
      reason: 'scrolling to the PHOTOMETRY charts cannot clear "track a star" '
          '— that is the same dead end one screen further down',
    );
    expect(find.text('Got it'), findsNothing, reason: 'and close the sheet');
  });

  testWidgets('the locked contribute rung does not offer its own export CTA',
      (tester) async {
    var toHud = 0;
    var scrolledToCharts = 0;
    await tester.pumpWidget(
      _card(
        hasExportableData: false,
        onPickTarget: () => toHud++,
        onJumpToPhotometry: () => scrolledToCharts++,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Contribute it'));
    await tester.pumpAndSettle();

    expect(
      find.text('Export data'),
      findsNothing,
      reason: 'this rung is locked precisely because there is nothing to '
          'export; offering the export hub would be a second dead end',
    );
    await tester.tap(find.text('Open Science HUD'));
    await tester.pumpAndSettle();
    expect(toHud, 1);
    expect(scrolledToCharts, 0);
  });

  testWidgets('a rung that is ready still shows its own CTA, not the unlock',
      (tester) async {
    await tester.pumpWidget(_card(hasExportableData: true));
    await tester.pump();

    await tester.tap(find.text('Contribute it'));
    await tester.pumpAndSettle();

    expect(find.text('Export data'), findsOneWidget);
    expect(find.text('Open Science HUD'), findsNothing);
  });

  testWidgets('a never-locked rung offers no unlock action', (tester) async {
    await tester.pumpWidget(_card(hasExportableData: false));
    await tester.pump();

    // Rung 1 "Measure your sky" has no prerequisite: it is ready from the
    // start, so an unlock button beside its CTA would be inventing a blocker.
    await tester.tap(find.text('Measure your sky'));
    await tester.pumpAndSettle();

    expect(find.text('Open Science HUD'), findsNothing);
  });
}
