// What Analytics means by "session", on two tabs.
//
// The Session tab's subject is the session in progress, so printing the HISTORY
// tab's copy verbatim ("No session history" / "Complete an imaging session to
// see history here") tells the user to go do the thing they have just done, and
// reads as a duplicate of the tab beside it.
//
// Loop captures carry no imaging_sessions row, so after 32 frames of manual loop
// capture, Analytics ▸ Session shows "Quick Capture · 32 exposures · 1m 4s"
// while History lists only the failed sequence run with 0 frames — the only
// frames the profile owns, invisible to History entirely.

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

DbCapturedImage _standaloneLight(int id) => DbCapturedImage(
      id: id,
      filePath: '/captures/l$id.fits',
      fileName: 'l$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 2,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 13, 8, 51, id),
      createdAt: DateTime.utc(2026, 8, 13, 8, 51, id),
      isAccepted: true,
      isPlateSolved: false,
      hfr: 2.1,
    );

ImagingSession _failedRun() => ImagingSession(
      id: 1,
      name: 'New Sequence',
      startTime: DateTime.utc(2026, 8, 13, 9, 2),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'failed',
    );

Widget _app({
  required AnalyticsTab tab,
  List<DbCapturedImage> standalone = const [],
  List<ImagingSession> sessions = const [],
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
        home: Scaffold(body: AnalyticsScreen(initialTab: tab)),
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 1200);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('the Session tab does not print the History tab empty state',
      (tester) async {
    await tester.pumpWidget(_app(tab: AnalyticsTab.session));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('No session history'),
      findsNothing,
      reason: 'this tab is about the session in progress, not the archive',
    );
    expect(
      find.text('Complete an imaging session to see history here'),
      findsNothing,
    );
    expect(find.text('Nothing captured yet'), findsOneWidget);
  });

  testWidgets('History counts frames captured outside a sequence',
      (tester) async {
    await tester.pumpWidget(_app(
      tab: AnalyticsTab.history,
      standalone: [for (var i = 1; i <= 32; i++) _standaloneLight(i)],
      sessions: [_failedRun()],
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('New Sequence'), findsOneWidget);
    // The card's label is a PanelHead eyebrow, which 03 §2 renders uppercase.
    expect(
      find.text('QUICK CAPTURES'),
      findsOneWidget,
      reason: 'the 32 frames the profile actually owns cannot be missing from '
          'the tab that claims to list the night',
    );
    // The count is a Readout now, not a number buried in a sentence.
    expect(
      tester
          .widgetList<Readout>(find.byType(Readout))
          .where((r) => r.label == 'Frames' && r.value == '32'),
      hasLength(1),
    );
  });

  testWidgets('History with only quick captures does not claim it is empty',
      (tester) async {
    await tester.pumpWidget(_app(
      tab: AnalyticsTab.history,
      standalone: [for (var i = 1; i <= 32; i++) _standaloneLight(i)],
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No session history'), findsNothing);
    expect(find.text('QUICK CAPTURES'), findsOneWidget);
    expect(find.textContaining('No sequence runs'), findsOneWidget);
  });

  testWidgets('a profile that has captured nothing still says so',
      (tester) async {
    await tester.pumpWidget(_app(tab: AnalyticsTab.history));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('No session history'), findsOneWidget);
    expect(find.text('Quick captures'), findsNothing);
  });
}
