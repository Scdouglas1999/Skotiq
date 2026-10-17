@Tags(['golden'])
library;

// Review-PNG goldens for the two renderings of the Morning Report plus the
// improvement-curve card, written to `docs/design/goldens/` for a reviewer to
// eyeball. Not pixel-diff guards — the assertions only confirm a real,
// non-empty image was produced (the harness prints the absolute PNG path).
//
//   * morning-report-narrative.png        — NarrativeView, full briefing
//   * morning-report-workbench.png        — WorkbenchView, dense console
//   * morning-report-improvement-curve.png — ImprovementCurvePanel, marked cut
//
// NarrativeView/WorkbenchView read the single `sessionReviewControllerProvider`,
// overridden here with the fully-seeded controller from the session_review
// fixture (master hero, multi-severity NightReport, IntegrationCurve with a
// marked cut, multi-night growth + best night, catalog annotation layer). The
// improvement-curve card is a pure widget fed the same seeded curve.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/improvement_curve_panel.dart';
import 'package:skotiq_app/screens/session_review/workbench_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart';
import '../screens/session_review/seeded_review_fixture.dart';
import 'surface_golden_harness.dart';

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  late SkotiqDatabase db;
  const scope = SessionReviewScope.session(1);

  setUp(() {
    db = mockDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('morning report — narrative view (dark)', (tester) async {
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final previewPath = await tester.runAsync(_writeSamplePng);
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ...seededReviewOverrides(
            db: db,
            scope: scope,
            previewPath: previewPath!,
          )
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: SkotiqColors.dark.background,
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: const SizedBox(
                  width: 1040,
                  height: 2540,
                  child: NarrativeView(scope: scope),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-narrative.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('morning report — workbench view (dark)', (tester) async {
    tester.view.physicalSize = const Size(1680, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final previewPath = await tester.runAsync(_writeSamplePng);
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ...seededReviewOverrides(
            db: db,
            scope: scope,
            previewPath: previewPath!,
          )
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: SkotiqColors.dark.background,
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: const SizedBox(
                  width: 1620,
                  height: 1640,
                  child: WorkbenchView(scope: scope),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-workbench.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('morning report — improvement curve panel (dark)',
      (tester) async {
    tester.view.physicalSize = const Size(820, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: SkotiqColors.dark.background,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                width: 760,
                color: SkotiqColors.dark.background,
                padding: const EdgeInsets.all(SkotiqTokens.spaceXl),
                child: ImprovementCurvePanel(curve: seededImprovementCurve()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-improvement-curve.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });
}

/// Let the seeded controller's load → loadSmartData publish and the charts /
/// image decode settle, without `pumpAndSettle` (charts + futures never idle).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Writes a 400×300 RGBA gradient PNG to a temp file for the hero base layer.
Future<String> _writeSamplePng() async {
  const w = 400;
  const h = 300;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final paint = Paint()
    ..shader = const LinearGradient(
      colors: [Color(0xFF101826), Color(0xFF243044)],
    ).createShader(rect);
  canvas.drawRect(rect, paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final dir = Directory.systemTemp.createTempSync('sk_review_golden');
  final file = File('${dir.path}/master_preview.png');
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  return file.path;
}
