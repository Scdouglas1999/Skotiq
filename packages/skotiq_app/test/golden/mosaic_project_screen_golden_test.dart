@Tags(['golden'])
library;

// Review-PNG goldens for the Mosaic project review screen, written to
// `docs/design/goldens/` for a reviewer to eyeball. Not pixel-diff guards — the
// assertions only confirm a real, non-empty image was produced (the harness
// prints the absolute PNG path).
//
//   * mosaic-project-mid-capture.png — some panels captured/integrated, no
//     stitch yet (Stitch gated, panel grid shows mixed statuses + thumbnails).
//   * mosaic-project-complete.png    — every panel integrated + the stitched
//     master shown via the reused MasterOverlayView.
//
// The screen reads the v45 mosaic DAOs through `databaseProvider`, so the
// fixture seeds an in-memory DB (project + panels + per-panel masters + the
// stitched output) and overrides only `databaseProvider`; the real DAOs +
// controller resolve everything else.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'surface_golden_harness.dart';

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  late SkotiqDatabase db;
  late Directory artifactsDir;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    artifactsDir = Directory.systemTemp.createTempSync('sk_mosaic_golden');
  });

  tearDown(() async {
    await db.close();
    if (artifactsDir.existsSync()) artifactsDir.deleteSync(recursive: true);
  });

  testWidgets('mosaic project — mid-capture (dark)', (tester) async {
    tester.view.physicalSize = const Size(1100, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final panelPng = await tester.runAsync(
      () => _writeSamplePng(artifactsDir, 'panel', const [
        Color(0xFF1B2A3A),
        Color(0xFF2E4B63),
      ]),
    );
    final projectId = await _seedProject(
      db,
      name: 'Veil Nebula 3x2',
      rows: 2,
      cols: 3,
      // First two panels integrated (with a master thumbnail), one captured,
      // one capturing, the rest pending — a realistic mid-capture spread.
      panels: [
        _PanelSeed(MosaicPanelStatus.integrated, 18, panelPng!),
        _PanelSeed(MosaicPanelStatus.integrated, 16, panelPng),
        _PanelSeed(MosaicPanelStatus.captured, 12, null),
        _PanelSeed(MosaicPanelStatus.capturing, 5, null),
        _PanelSeed(MosaicPanelStatus.pending, 0, null),
        _PanelSeed(MosaicPanelStatus.pending, 0, null),
      ],
      status: MosaicProjectStatus.integrating,
    );

    final file = await _capture(
      tester,
      db: db,
      projectId: projectId,
      width: 1040,
      height: 1440,
      fileName: 'mosaic-project-mid-capture.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mosaic project — complete with stitched master (dark)',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final panelPng = await tester.runAsync(
      () => _writeSamplePng(artifactsDir, 'panel', const [
        Color(0xFF1B2A3A),
        Color(0xFF2E4B63),
      ]),
    );
    final mosaicPng = await tester.runAsync(
      () => _writeSamplePng(
          artifactsDir,
          'mosaic',
          const [
            Color(0xFF101826),
            Color(0xFF3A2E63),
          ],
          width: 900,
          height: 400),
    );

    final projectId = await _seedProject(
      db,
      name: 'Veil Nebula 3x2',
      rows: 2,
      cols: 3,
      panels: [
        for (var i = 0; i < 6; i++)
          _PanelSeed(MosaicPanelStatus.integrated, 16 + i, panelPng!),
      ],
      status: MosaicProjectStatus.complete,
      stitchedPreviewPng: mosaicPng!,
    );

    final file = await _capture(
      tester,
      db: db,
      projectId: projectId,
      width: 1040,
      height: 1940,
      fileName: 'mosaic-project-complete.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });
}

/// One seeded panel: its terminal status, captured-frame count, and an optional
/// on-disk preview PNG (when integrated, so the grid shows a master thumbnail).
class _PanelSeed {
  final MosaicPanelStatus status;
  final int capturedCount;
  final String? previewPng;

  _PanelSeed(this.status, this.capturedCount, this.previewPng);
}

/// Seed a project + its panels (and, for integrated panels, a per-panel master
/// linked onto the panel), plus an optional stitched output master. Returns the
/// project id.
Future<int> _seedProject(
  SkotiqDatabase db, {
  required String name,
  required int rows,
  required int cols,
  required List<_PanelSeed> panels,
  required MosaicProjectStatus status,
  String? stitchedPreviewPng,
}) async {
  final projectsDao = MosaicProjectsDao(db);
  final panelsDao = MosaicPanelsDao(db);
  final mastersDao = IntegratedMastersDao(db);

  int? outputMasterId;
  final projectId = await projectsDao.create(
    name: name,
    rows: rows,
    cols: cols,
    overlapPct: 15.0,
    status: status,
  );

  for (var i = 0; i < panels.length; i++) {
    final seed = panels[i];
    final panelId = await panelsDao.upsert(
      projectId: projectId,
      panelIndex: i,
      centerRa: 20.76 + (i % cols) * 0.02 - 0.02,
      centerDec: 31.0 + (i ~/ cols) * 0.3 - 0.15,
    );
    if (seed.previewPng != null &&
        seed.status == MosaicPanelStatus.integrated) {
      final masterId = await mastersDao.insertMaster(
        name: '$name Panel ${i + 1}',
        masterFitsPath: '${seed.previewPng}.fits',
        previewPngPath: seed.previewPng,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        width: 100,
        height: 80,
        frameCount: seed.capturedCount,
      );
      await panelsDao.setMaster(panelId, masterId);
    } else {
      await panelsDao.updateStatus(panelId, seed.status);
    }
    if (seed.capturedCount > 0) {
      await panelsDao.incrementCaptured(panelId, delta: seed.capturedCount);
    }
  }

  if (stitchedPreviewPng != null) {
    outputMasterId = await mastersDao.insertMaster(
      name: '$name · Mosaic',
      masterFitsPath: '$stitchedPreviewPng.fits',
      previewPngPath: stitchedPreviewPng,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      width: 900,
      height: 400,
      frameCount: panels.length,
    );
    await projectsDao.setOutputMaster(projectId, outputMasterId);
  }

  return projectId;
}

/// Pump the screen with `databaseProvider` overridden to the seeded in-memory
/// DB, settle the async load + image decode, and capture the boundary.
Future<File> _capture(
  WidgetTester tester, {
  required SkotiqDatabase db,
  required int projectId,
  required double width,
  required double height,
  required String fileName,
}) async {
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: SkotiqColors.dark.background,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: width,
                height: height,
                // Inject an explicit (temp) artifacts dir so the screen
                // bypasses the async durable-artifacts-dir resolution
                // (getApplicationSupportDirectory is unavailable in a widget
                // test); the golden only renders the loaded review chrome.
                child: MosaicProjectScreen(
                  projectId: projectId,
                  artifactsBaseDir: '/tmp/mosaic',
                ),
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
    fileName: fileName,
  );
  return file;
}

/// Let the controller's async load publish and the image decodes settle,
/// without `pumpAndSettle` (the indeterminate progress bar never idles).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Writes a [width]x[height] RGBA gradient PNG to [dir] and returns its path.
Future<String> _writeSamplePng(
  Directory dir,
  String stem,
  List<Color> colors, {
  int width = 200,
  int height = 160,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final paint = Paint()
    ..shader = LinearGradient(colors: colors).createShader(rect);
  canvas.drawRect(rect, paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File('${dir.path}/${stem}_${colors.length}_$width.png');
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  return file.path;
}
