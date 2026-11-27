// Analytics' Session and Science tabs pick the session in view by one rule:
// the operator's pick, else the live session, else the session the
// Science tab opens on, else the newest session. With no science default the
// Session tab shows the newest session, as the Science tab does, instead of
// the quick captures.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ImagingSession _session(int id, int hour) => ImagingSession(
      id: id,
      name: 'Night $id',
      startTime: DateTime.utc(2026, 8, 13, hour),
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

Widget _app(AnalyticsTab tab) => ProviderScope(
      overrides: [
        standaloneImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        allDbImagesProvider
            .overrideWith((ref) => Stream.value(const <DbCapturedImage>[])),
        // Newest first, as the sessions DAO lists them.
        allSessionsProvider.overrideWith(
          (ref) => Stream.value([_session(2, 22), _session(1, 20)]),
        ),
        scienceDefaultSessionProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: AnalyticsScreen(initialTab: tab)),
      ),
    );

int? _reviewing(WidgetTester tester) =>
    tester.widget<SessionPicker<int>>(find.byType(SessionPicker<int>)).value;

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1400, 900);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  for (final tab in [AnalyticsTab.session, AnalyticsTab.science]) {
    testWidgets('${tab.name} falls back to the newest session', (
      tester,
    ) async {
      await tester.pumpWidget(_app(tab));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(_reviewing(tester), 2);
    });
  }
}
