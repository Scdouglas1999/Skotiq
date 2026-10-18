// Analytics ▸ Session for a night that returned frames and kept none.
//
// Live: a "Reviewing: New Sequence · Sep 14 · 3 frames" bar sat over a
// separate SESSION card that named the same session and date again, and four
// ~250 px chart cards each said "No … recorded for these frames".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
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

DbCapturedImage _frame(int id, {required bool accepted, double? hfr}) =>
    DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 60,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 9, 14, 22, 50 + id),
      createdAt: DateTime.utc(2026, 9, 14, 22, 50 + id),
      isAccepted: accepted,
      isPlateSolved: false,
      sessionId: 1,
      hfr: hfr,
    );

final _night = ImagingSession(
  id: 1,
  name: 'New Sequence',
  startTime: DateTime.utc(2026, 9, 14, 22, 44),
  totalExposures: 3,
  successfulExposures: 3,
  failedExposures: 0,
  totalIntegrationSecs: 0,
  autofocusCount: 0,
  status: 'failed',
);

Widget _app(List<DbCapturedImage> frames) => ProviderScope(
      overrides: [
        standaloneImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allDbImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allSessionsProvider.overrideWith((ref) => Stream.value([_night])),
        latestScienceSessionProvider.overrideWith((ref) async => 1),
        latestScienceProductSessionProvider.overrideWith((ref) async => 1),
        dbSessionImagesProvider(1).overrideWith((ref) => Stream.value(frames)),
        tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: AnalyticsScreen(initialTab: AnalyticsTab.session),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, List<DbCapturedImage> frames) async {
  tester.view.physicalSize = const Size(1648, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(frames));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('the picker is the session panel\'s header, not a second bar',
      (tester) async {
    await _pump(tester, [
      for (var i = 1; i <= 3; i++) _frame(i, accepted: false),
    ]);

    final reviewing = find.text('Reviewing');
    expect(reviewing, findsOneWidget);
    final sessionPanel = find.ancestor(
      of: find.text('SESSION'),
      matching: find.byType(SkotiqPanel),
    );
    expect(
      find.descendant(of: sessionPanel, matching: reviewing),
      findsOneWidget,
      reason: 'the session is named once, inside the panel it describes',
    );
    expect(
      find.textContaining('Mon Sep 14, 2026'),
      findsNothing,
      reason: 'the date is already in the picker',
    );
    expect(find.text('failed'), findsOneWidget);
  });

  testWidgets('no frame with anything to plot is one line, not four charts',
      (tester) async {
    await _pump(tester, [
      for (var i = 1; i <= 3; i++) _frame(i, accepted: false),
    ]);

    expect(find.byType(SessionChart), findsNothing);
    expect(
      find.text(
        'No accepted light frames to chart · 3 excluded (rejected or '
        'calibration)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('one plotted value brings the charts back', (tester) async {
    await _pump(tester, [
      _frame(1, accepted: true, hfr: 2.4),
      _frame(2, accepted: true),
    ]);

    expect(find.byType(SessionChart), findsNWidgets(4));
  });
}
