import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
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
  required double exposure,
  double? hfr,
}) =>
    DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: type,
      exposureDuration: exposure,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 14),
      createdAt: DateTime.utc(2026, 7, 14),
      isAccepted: accepted,
      isPlateSolved: false,
      hfr: hfr,
    );

Widget _app(Stream<List<DbCapturedImage>> standalone) {
  return ProviderScope(
    overrides: [
      standaloneImagesProvider.overrideWith((ref) => standalone),
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

/// The four summary numbers, as the widgets that carry them.
///
/// They are [Readout]s since the Observatory pass: a null value is how a
/// readout says "not known", and it renders the one em dash rather than a word
/// parked in a value slot.
List<String?> _summaryValues(WidgetTester tester) {
  return tester
      .widgetList<Readout>(find.byType(Readout))
      .take(4)
      .map((readout) => readout.value)
      .toList(growable: false);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1200, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('quick capture summary reflects its actual standalone frames',
      (tester) async {
    await tester.pumpWidget(
      _app(Stream.value([
        _image(id: 1, type: 'light', accepted: true, exposure: 45, hfr: 2),
        _image(id: 2, type: 'light', accepted: false, exposure: 120, hfr: 10),
        _image(id: 3, type: 'flat', accepted: true, exposure: 2),
      ])),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Quick Capture'), findsOneWidget);
    // Exposures counts LIGHT frames as accepted/total, matching the integration
    // and median-HFR figures beside it (both lights-only). Counting every frame
    // instead reported "3" next to an integration of a single 45 s sub, because
    // the rejected light and the flat contributed to one stat but not the
    // others.
    expect(_summaryValues(tester), [null, '1/2', '45s', '2.00']);
  });

  testWidgets('standalone image failures stay distinct from empty data',
      (tester) async {
    await tester.pumpWidget(
      _app(Stream.error(StateError('image catalog offline'))),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // The four numbers are unknown, and a readout says that with the em dash.
    // They used to read 'Unavailable', which is a word standing where a
    // measurement goes; the DISTINCTION from empty data is carried by the
    // banner below, which is the screen's one error surface.
    expect(_summaryValues(tester), [null, null, null, null]);
    expect(find.textContaining('Frames did not load'), findsOneWidget);
    expect(find.textContaining('image catalog offline'), findsOneWidget);
  });
}
