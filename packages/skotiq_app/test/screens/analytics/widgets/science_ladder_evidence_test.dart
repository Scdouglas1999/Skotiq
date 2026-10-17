// The Science guide must reflect the data on the page it sits above.
//
// Observed defect: with 80 photometry points plotted, a Lomb-Scargle period on
// screen and an enabled "Export to AAVSO" button, the guide still highlighted
// rung 1 and rung 3 opened on a padlock reading "Turn on live photometry and
// track a star to start collecting points." The rungs cascaded — each computed
// from the state of the one above — so a single missing photometric
// calibration locked four rungs the user had demonstrably already climbed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_onboarding/science_ladder_card.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_onboarding/science_ladder_model.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _card() => ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ScienceLadderCard(
              // The reviewed night: photometry recorded, a period found, data
              // ready to export — but no photometric calibration was ever run.
              hasCalibration: false,
              hasTarget: false,
              photometryLive: false,
              lightCurvePoints: 80,
              hasPeriodResult: true,
              hasExportableData: true,
              onJumpToPhotometry: () {},
              onRunCalibration: () {},
              onPickTarget: () {},
              onOpenExport: () {},
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 1600);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('the light-curve rung is not padlocked over an 80-point curve',
      (tester) async {
    await tester.pumpWidget(_card());
    await tester.pump();

    await tester.tap(find.text('Build a light curve'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Turn on live photometry'),
      findsNothing,
      reason: '80 points are already collected',
    );
    // A done rung offers no CTA and no prerequisite.
    expect(find.textContaining('start collecting points'), findsNothing);
  });

  testWidgets('the contribute rung offers its export when data exists',
      (tester) async {
    await tester.pumpWidget(_card());
    await tester.pump();

    await tester.tap(find.text('Contribute it'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Find a period'),
      findsNothing,
      reason: 'a period was found and is on screen',
    );
    expect(find.text('Export data'), findsOneWidget);
  });

  test('evidence beats the cascade', () {
    final progress = evaluateLadder(
      hasCalibration: false,
      hasTarget: false,
      photometryLive: false,
      lightCurvePoints: 80,
      hasPeriodResult: true,
      hasExportableData: true,
    );

    expect(progress.states[ScienceRung.measure], RungState.ready);
    expect(progress.states[ScienceRung.track], RungState.done);
    expect(progress.states[ScienceRung.curve], RungState.done);
    expect(progress.states[ScienceRung.period], RungState.done);
    expect(progress.states[ScienceRung.contribute], RungState.ready);
  });
}
