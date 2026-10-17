// Light widget tests for the two renderings of the Morning Report:
// `NarrativeView` and `WorkbenchView`. Both read the single
// `sessionReviewControllerProvider(scope)`; here that provider is overridden
// with a fully-seeded [SeededReviewController] (a representative master hero,
// a multi-severity NightReport, an IntegrationCurve with a marked cut, a
// multi-night growth series + best night, and a catalog annotation layer).
//
// The assertion is structural: each view builds and pumps without throwing,
// and the seeded data surfaces (verdict headline, curve callout, growth badge,
// finishing actions / mixer). These are not pixel guards — the golden tests in
// `test/golden/` produce the inspectable PNGs.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/workbench_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import 'seeded_review_fixture.dart';

void main() {
  late SkotiqDatabase db;
  late SessionReviewScope scope;
  late String previewPath;

  setUp(() async {
    db = mockDatabase();
    scope = const SessionReviewScope.session(1);
    previewPath = await _writeSamplePng();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpView(WidgetTester tester, Widget view, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...seededReviewOverrides(
            db: db,
            scope: scope,
            previewPath: previewPath,
          )
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: SkotiqColors.dark.background,
            body: view,
          ),
        ),
      ),
    );
    // Let the controller's load → loadSmartData seed publish, then settle a few
    // frames (pump, not pumpAndSettle — thumbnail futures/charts never idle).
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('NarrativeView builds with a full seeded report', (tester) async {
    await pumpView(
      tester,
      NarrativeView(scope: scope),
      const Size(1000, 2200),
    );

    expect(tester.takeException(), isNull);
    // Verdict headline + section headers render off the seeded model.
    expect(
      find.text('Solid night — focus drifted late, but most subs are keepers.'),
      findsOneWidget,
    );
    expect(find.text('How deep is deep enough?'), findsOneWidget);
    expect(find.text('This project over time'), findsOneWidget);
    expect(find.text('Calibrated & annotated'), findsOneWidget);
    // The Night Doctor finding cards surfaced.
    expect(find.text('Clouds cost 6 subs'), findsOneWidget);
    expect(find.text('Focus drifted as the night cooled'), findsOneWidget);
  });

  testWidgets('WorkbenchView builds with a full seeded report', (tester) async {
    await pumpView(
      tester,
      WorkbenchView(scope: scope),
      const Size(1600, 2400),
    );

    expect(tester.takeException(), isNull);
    // Workbench section headers render.
    expect(find.text('Subs & culling'), findsOneWidget);
    expect(find.text('Master & overlays'), findsOneWidget);
    expect(find.text('Narrowband mixer'), findsOneWidget);
    expect(find.text('A / B compare'), findsOneWidget);
    expect(find.text('Integration settings'), findsOneWidget);
  });
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
  final dir = Directory.systemTemp.createTempSync('ns_review_view');
  final file = File('${dir.path}/master_preview.png');
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  return file.path;
}
