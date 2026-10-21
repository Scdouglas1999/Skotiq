// Renders the Darkroom pass view from a real pass's recorded log at three
// moments, at the full window in both themes, at a narrow window and at the
// side panel's width.
//
// The log is a pass record the app wrote (`<image output>/darkroom/passes/
// <run>.json`) or the bridge harness's `pass_telemetry.json`, so every number
// and image is what the pipeline produced. Opt-in: set PASSVIZ_LOG to the log
// file and PASSVIZ_SHOTS to where the PNGs go.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/pass_view/pass_view.dart';
import 'package:skotiq_app/screens/darkroom/pass_view/pass_view_parts.dart'
    show PassImageSource;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../golden/surface_golden_harness.dart';

/// A record file, or the harness's flat list of `{t, kind, detail}`.
PassLog _readLog(String path) {
  final raw = jsonDecode(File(path).readAsStringSync());
  if (raw is Map) return PassLog.fromJson(raw)!;
  return PassLog(
    runId: 'harness',
    entries: (raw as List)
        .map(PassLogEntry.fromJson)
        .whereType<PassLogEntry>()
        .toList(),
  );
}

/// Every preview the log names, decoded once outside the fake clock.
final Map<String, ui.Image> _decoded = <String, ui.Image>{};

Future<void> _decodeAll(PassLog log) async {
  for (final e in log.entries) {
    for (final key in const ['path', 'previewPath']) {
      final path = e.detail[key];
      if (path is! String || _decoded.containsKey(path)) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      final codec = await ui.instantiateImageCodec(
        file.readAsBytesSync(),
        targetWidth: 1200,
      );
      _decoded[path] = (await codec.getNextFrame()).image;
    }
  }
}

void main() {
  final logPath = Platform.environment['PASSVIZ_LOG'];
  final shots = Platform.environment['PASSVIZ_SHOTS'];
  final skip = logPath == null || shots == null;

  setUpAll(SurfaceGoldenHarness.ensureCaptureFonts);

  Future<void> capture(
    WidgetTester tester, {
    required PassSnapshot snapshot,
    required Size size,
    required ThemeData theme,
    required SkotiqColors colors,
    required String name,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    Widget app(Key root) => MaterialApp(
          key: root,
          theme: theme,
          themeAnimationDuration: Duration.zero,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: colors.background,
            body: RepaintBoundary(
              key: key,
              child: SizedBox.fromSize(
                size: size,
                child: PassImageSource(
                  builder: (path) {
                    final image = _decoded[path];
                    return image == null
                        ? null
                        : RawImage(image: image, fit: BoxFit.contain);
                  },
                  child: PassView(snapshot: snapshot, onStop: () {}),
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(app(UniqueKey()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull, reason: name);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(shots!).createSync(recursive: true);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('pass view at three moments from a recorded pass', (
    tester,
  ) async {
    final log = _readLog(logPath!);
    await tester.runAsync(() => _decodeAll(log));
    // PASSVIZ_RATES names a stored rates.json: the stage timings an earlier
    // pass left, as the app reads them to estimate stages not yet run.
    final ratesPath = Platform.environment['PASSVIZ_RATES'];
    final history = ratesPath == null
        ? const <String, double>{}
        : <String, double>{
            for (final e in (jsonDecode(File(ratesPath).readAsStringSync())
                    as Map<String, dynamic>)
                .entries)
              e.key: (e.value as num).toDouble(),
          };
    final timeline = PassTimeline.fromLog(log, history: history);
    final lead = timeline.lanes.first;
    final reg = lead.span(PassStage.register);
    final norm = lead.span(PassStage.normalize);
    final moments = <String, Duration>{
      // Registering the sixth luminance sub, five measured.
      'early': reg.ticks[4] + const Duration(milliseconds: 300),
      // Eight luminance subs in the running mean.
      'mid': norm.ticks[7] + const Duration(milliseconds: 300),
      // The whole pass, as its record reads.
      'late': timeline.recorded,
    };
    final sizes = <String, Size>{
      'desktop-1536x864': const Size(1536, 864),
      'narrow-1000x760': const Size(1000, 760),
      'panel-360x1500': const Size(360, 1500),
    };
    for (final MapEntry(key: moment, value: t) in moments.entries) {
      final snapshot = timeline.at(t);
      for (final MapEntry(key: sizeName, value: size) in sizes.entries) {
        await capture(
          tester,
          snapshot: snapshot,
          size: size,
          theme: SkotiqTheme.dark,
          colors: SkotiqColors.dark,
          name: '$moment-$sizeName-dark',
        );
      }
      await capture(
        tester,
        snapshot: snapshot,
        size: const Size(1536, 864),
        theme: SkotiqTheme.light,
        colors: SkotiqColors.light,
        name: '$moment-desktop-1536x864-light',
      );
    }
  }, skip: skip);
}
