import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/analytics/widgets/session_chart.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

DbCapturedImage _image({
  required int id,
  required String type,
  required bool accepted,
  double? hfr,
  double? guidingRms,
  int? focuserPosition,
  double? sensorTemp,
}) =>
    DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: type,
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 14, 22, id),
      createdAt: DateTime.utc(2026, 7, 14, 22, id),
      isAccepted: accepted,
      isPlateSolved: false,
      hfr: hfr,
      guidingRmsTotal: guidingRms,
      focuserPosition: focuserPosition,
      sensorTemp: sensorTemp,
    );

Widget _app(List<DbCapturedImage> images) {
  return ProviderScope(
    overrides: [
      standaloneImagesProvider.overrideWith((ref) => Stream.value(images)),
      allDbImagesProvider.overrideWith(
        (ref) => Stream.value(const <DbCapturedImage>[]),
      ),
      allSessionsProvider.overrideWith(
        (ref) => Stream.value(const <ImagingSession>[]),
      ),
      tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(
        body: AnalyticsScreen(initialTab: AnalyticsTab.session),
      ),
    ),
  );
}

Map<String, SessionChart> _chartsByTitle(WidgetTester tester) {
  return {
    for (final chart in tester.widgetList<SessionChart>(
      find.byType(SessionChart),
    ))
      chart.title: chart,
  };
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1400, 2400);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('all four session charts plot the same accepted-light frames',
      (tester) async {
    await tester.pumpWidget(
      _app([
        _image(
          id: 1,
          type: 'light',
          accepted: true,
          hfr: 2.0,
          guidingRms: 0.50,
          focuserPosition: 15000,
          sensorTemp: -10,
        ),
        _image(
          id: 2,
          type: 'light',
          accepted: true,
          hfr: 2.2,
          guidingRms: 0.95,
          focuserPosition: 15010,
          sensorTemp: -10,
        ),
        // Graded out: its 4.2" guiding and 15100-step focus excursion are why
        // it was rejected, and they must not colour the night's charts.
        _image(
          id: 3,
          type: 'light',
          accepted: false,
          hfr: 9.9,
          guidingRms: 4.20,
          focuserPosition: 15100,
          sensorTemp: -10,
        ),
        // A dark carries a real sensor temperature but is not part of the
        // night the other three charts describe.
        _image(id: 4, type: 'dark', accepted: true, sensorTemp: -10),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final charts = _chartsByTitle(tester);
    expect(charts.keys, hasLength(4));
    for (final entry in charts.entries) {
      expect(
        entry.value.dataPoints,
        hasLength(2),
        reason: '${entry.key} plots a different population from the others',
      );
    }

    final guiding = charts['Guiding performance']!;
    expect(
      guiding.dataPoints.map((p) => p.value),
      everyElement(lessThanOrEqualTo(0.95)),
      reason: 'rejected frames must not enter the guiding trace',
    );

    expect(
      find.textContaining('2 accepted light frames'),
      findsOneWidget,
      reason: 'the card must state the population it plots',
    );
    expect(find.textContaining('2 excluded'), findsOneWidget);
  });
}
