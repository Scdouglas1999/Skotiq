// Pumps one routed screen of the real app (the real router, the real shell
// with its rail or phone bar and title bar) over a seeded in-memory database,
// and writes the frame to a PNG.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/screens/shell/widgets/startup_splash_gate.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/pump_app_screen.dart' show TestBackendNotifier;
import '../surface_golden_harness.dart';

/// One public screenshot: where the app is, at what size, and what it shows
/// beyond the shared night.
class Shot {
  const Shot({
    required this.fileName,
    required this.location,
    required this.description,
    this.size = desktopSize,
    this.pixelRatio = 1,
    this.overrides = const <Override>[],
    this.prepare,
    this.loadTime = Duration.zero,
  });

  /// The size of the site's existing captures (a 1920 x 1080 window), so a
  /// new file drops into the same slot and the tour crops keep their scale.
  static const Size desktopSize = Size(1920, 1080);

  /// A current phone, captured at its device pixel ratio.
  static const Size phoneSize = Size(390, 844);

  bool get isPhone => size.width < 768;

  final String fileName;
  final String location;
  final String description;
  final Size size;
  final double pixelRatio;
  final List<Override> overrides;

  /// Runs after the screen has drawn and loaded, before the capture: the
  /// state the screen reaches after it opens (a run that finished, a row the
  /// user picked).
  final Future<void> Function(WidgetTester tester, ProviderContainer container)?
      prepare;

  /// Real time the screen needs beyond the usual settle to finish loading
  /// (scoring the whole catalog, say).
  final Duration loadTime;
}

/// Seeds the database before the screen is pumped.
typedef DatabaseSeed = Future<void> Function(SkotiqDatabase db);

MockBackend _quietBackend() {
  final backend = mockBackend();
  when(() => backend.sequencerSetCheckpointDir(any())).thenAnswer((_) async {});
  when(() => backend.hasCheckpoint()).thenAnswer((_) async => false);
  return backend;
}

Future<File> captureShot(
  WidgetTester tester,
  Shot shot, {
  required List<Override> shared,
  required DatabaseSeed seed,
  void Function(MockBackend backend)? stubBackend,
}) async {
  await SurfaceGoldenHarness.ensureCaptureFonts();

  const windowManager = MethodChannel('window_manager');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    windowManager,
    (call) async => null,
  );

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = shot.size;

  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  await tester.runAsync(() => seed(db));

  final container = ProviderContainer(
    overrides: <Override>[
      databaseProvider.overrideWithValue(db),
      backendProvider.overrideWith(
        (ref) {
          final backend = _quietBackend();
          stubBackend?.call(backend);
          return TestBackendNotifier(ref, backend);
        },
      ),
      appVersionProvider.overrideWithValue(
        const AppVersionInfo(version: '9.0.1', buildNumber: 0),
      ),
      ...shared,
      ...shot.overrides,
    ],
  );
  final GoRouter router = container.read(appRouterProvider);
  router.go(shot.location);

  final boundaryKey = GlobalKey();
  try {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: SkotiqTheme.dark,
            localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
            supportedLocales: SkotiqLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      ),
    );
    // Past the brand splash: its draw runs on a timer, then it fades.
    for (var i = 0;
        i < 80 &&
            container.read(skotiqSplashPhaseProvider) != SkotiqSplashPhase.done;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Let async providers and the database answer, and let the page
    // transition finish. `runAsync` is what lets real async (drift, image
    // decoding) complete between frames.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    for (var waited = Duration.zero;
        waited < shot.loadTime;
        waited += const Duration(milliseconds: 200)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (shot.prepare != null) {
      await shot.prepare!(tester, container);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final out =
        File('${SurfaceGoldenHarness.screenshotsDir().path}/${shot.fileName}');
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: shot.pixelRatio);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) {
          throw StateError('PNG encode failed for ${shot.fileName}');
        }
        out.writeAsBytesSync(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    expect(tester.takeException(), isNull, reason: shot.fileName);
    return out;
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    container.dispose();
    // Drift closes the screen's query streams on zero-length timers.
    await tester.pump(const Duration(milliseconds: 50));
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManager, null);
    tester.view.reset();
  }
}
