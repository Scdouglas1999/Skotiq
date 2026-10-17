// Analytics must not invent a session for a user who has not imaged.
//
// Observed with imaging_sessions and captured_images both empty (a brand-new
// profile): the Session tab — the first thing Analytics shows — rendered a card
// headed "Quick Capture / Standalone snapshots taken outside sequences" with
// DURATION "—", EXPOSURES 0, INTEGRATION "No data", MEDIAN HFR "No data" and
// four blank charts. The History tab in the same state says so properly.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao());

  @override
  // ignore: invalid_use_of_protected_member
  TutorialProgress get state => const TutorialProgress(tutorialsEnabled: false);
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

DbCapturedImage _standalone(int id) => DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 30,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 14),
      createdAt: DateTime.utc(2026, 7, 14),
      isAccepted: true,
      isPlateSolved: false,
      hfr: 2.2,
    );

ImagingSession _session(int id) => ImagingSession(
      id: id,
      name: 'Night A — M31',
      startTime: DateTime.utc(2026, 7, 14),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

Widget _app({
  required List<DbCapturedImage> standalone,
  required List<ImagingSession> sessions,
}) =>
    ProviderScope(
      overrides: [
        standaloneImagesProvider
            .overrideWith((ref) => Stream.value(standalone)),
        allDbImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allSessionsProvider.overrideWith((ref) => Stream.value(sessions)),
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: AnalyticsScreen(initialTab: AnalyticsTab.session),
        ),
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('a profile with nothing captured gets an empty state',
      (tester) async {
    await tester.pumpWidget(_app(standalone: const [], sessions: const []));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Quick Capture'),
      findsNothing,
      reason: 'naming a session, a duration and an exposure count for a night '
          'that never happened is the same class of claim as the rest of this '
          'report',
    );
    expect(find.byType(ResponsiveStatStrip), findsNothing);
    // This tab's subject is the session in progress, so its empty state must
    // not be the History tab's copy — that tells the user to go do what they
    // have just done.
    expect(find.text('Nothing captured yet'), findsOneWidget);
    expect(find.text('No session history'), findsNothing);
  });

  testWidgets('the quick-capture bucket still appears when it holds frames',
      (tester) async {
    await tester.pumpWidget(
      _app(standalone: [_standalone(1)], sessions: const []),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Quick Capture'), findsOneWidget);
    // The four summary numbers are Readouts since the Observatory pass. The
    // charts below carry readouts of their own (median / p90 / range / n), so
    // this asserts the four the summary panel owns, by label.
    final labels = tester
        .widgetList<Readout>(find.byType(Readout))
        .map((r) => r.label)
        .toList(growable: false);
    expect(labels, containsAll(<String>['Exposures', 'Median HFR']));
  });

  testWidgets('with sessions on record the picker stays and says so',
      (tester) async {
    await tester.pumpWidget(
      _app(standalone: const [], sessions: [_session(1)]),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // No session is under review (no live run, no science session resolved),
    // so the tab would previously have fabricated the Quick Capture card.
    expect(find.text('Quick Capture'), findsNothing);
    expect(find.text('No quick captures'), findsOneWidget);
    expect(find.text('Choose a session above to review it.'), findsOneWidget);
    expect(find.text('Reviewing'), findsOneWidget);
  });
}
