// Analytics > Science picks its view with a switch inside the page, under the
// one header tab row, and names its session with the same picker as Session.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ImagingSession _run(int id) => ImagingSession(
      id: id,
      name: 'Rig run $id',
      startTime: DateTime.utc(2026, 11, 3, 20),
      totalExposures: 12,
      successfulExposures: 12,
      failedExposures: 0,
      totalIntegrationSecs: 600,
      autofocusCount: 0,
      status: 'completed',
    );

Widget _app({ScienceTab? view, AnalyticsTab tab = AnalyticsTab.science}) =>
    ProviderScope(
      overrides: [
        standaloneImagesProvider.overrideWith(
          (ref) => Stream.value(const <DbCapturedImage>[]),
        ),
        allDbImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allSessionsProvider.overrideWith((ref) => Stream.value([_run(1)])),
        scienceDefaultSessionProvider.overrideWith((ref) async => 1),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: AnalyticsScreen(initialTab: tab, initialScienceView: view),
        ),
      ),
    );

Future<void> _pumpFrames(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1600, 1000);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('the views are a switch in the page, not a second tab row',
      (tester) async {
    await tester.pumpWidget(_app());
    await _pumpFrames(tester);

    expect(find.byType(AdaptiveTabBar), findsOneWidget);
    final views =
        tester.widget<SegmentedControl>(find.byType(SegmentedControl).first);
    expect(views.segments, ['Measurements', 'First light', 'Observing alerts']);
    expect(views.selectedIndex, ScienceTab.workspace.index);

    await tester.tap(find.text('Observing alerts'));
    await _pumpFrames(tester);
    expect(
      tester
          .widget<SegmentedControl>(find.byType(SegmentedControl).first)
          .selectedIndex,
      ScienceTab.transients.index,
    );
    expect(find.byTooltip('Refresh alerts'), findsOneWidget);
  });

  testWidgets('a link to a view opens it', (tester) async {
    await tester.pumpWidget(_app(view: ScienceTab.firstLight));
    await _pumpFrames(tester);
    expect(
      tester
          .widget<SegmentedControl>(find.byType(SegmentedControl).first)
          .selectedIndex,
      ScienceTab.firstLight.index,
    );
  });

  testWidgets('the measurements view has no second way into the alerts',
      (tester) async {
    await tester.pumpWidget(_app());
    await _pumpFrames(tester);
    expect(find.textContaining('(Transients)'), findsNothing);
  });

  testWidgets('Session and Science name the session with the same picker',
      (tester) async {
    for (final tab in [AnalyticsTab.session, AnalyticsTab.science]) {
      await tester.pumpWidget(_app(tab: tab));
      await _pumpFrames(tester);
      final picker = find.byType(SessionPicker<int>);
      expect(picker, findsOneWidget, reason: '$tab has one session picker');
      expect(tester.widget<SessionPicker<int>>(picker).value, 1);
      expect(
        find.descendant(
          of: picker,
          matching: find.textContaining('12 exposures'),
        ),
        findsOneWidget,
      );
    }
  });
}
