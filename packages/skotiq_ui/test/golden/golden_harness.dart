import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared support for the committed design-language golden screenshots.
///
/// These tests are NOT `matchesGoldenFile` pixel-diff guards — they are a
/// review harness. They render a real design-system surface under a real
/// Skotiq theme (with the actual bundled fonts loaded so text is legible,
/// not Ahem boxes) and write the rasterised frame as a PNG into
/// `docs/design/goldens/` so the lead engineer can eyeball the rendered design
/// language. The absolute output path is printed for each capture.
///
/// Writing those tracked PNGs is OPT-IN: set `SKOTIQ_CAPTURE_ASSETS=1` to
/// refresh them. Without it the capture still runs in full but lands in a temp
/// directory, so a plain `flutter test` leaves the working tree clean. See
/// `docs/testing/golden-tests.md`.
abstract final class GoldenHarness {
  GoldenHarness._();

  static bool _fontsLoaded = false;

  /// Loads the bundled Hanken Grotesk + Spline Sans Mono variable fonts into the
  /// test font collection so captured PNGs render the real typefaces rather than
  /// the fallback test font. Idempotent.
  static Future<void> ensureFonts() async {
    if (_fontsLoaded) return;
    final root = repoRoot().path;
    await _loadFont(
      'HankenGrotesk',
      '$root/packages/skotiq_ui/assets/fonts/HankenGrotesk-VF.ttf',
    );
    await _loadFont(
      'SplineSansMono',
      '$root/packages/skotiq_ui/assets/fonts/SplineSansMono-VF.ttf',
    );
    // The Lucide glyph font is a package asset (family "Lucide", package
    // "lucide_icons" → resolved family "packages/lucide_icons/Lucide"). Load it
    // so HUD/nav/button icons render as real glyphs in the captured PNGs
    // instead of tofu boxes.
    await _loadFont('packages/lucide_icons/Lucide', resolveLucideTtf());
    _fontsLoaded = true;
  }

  /// Resolves the absolute path to the bundled Lucide icon font by reading the
  /// caller package's `.dart_tool/package_config.json`. Fails loud if the
  /// dependency or its asset cannot be found.
  static String resolveLucideTtf() {
    final config = File(
      '${Directory.current.path}/.dart_tool/'
      'package_config.json',
    );
    if (!config.existsSync()) {
      throw StateError(
        'package_config.json not found for golden font load: '
        '${config.path}',
      );
    }
    final decoded =
        jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    final packages = (decoded['packages'] as List).cast<Map<String, dynamic>>();
    final lucide = packages.firstWhere(
      (p) => p['name'] == 'lucide_icons',
      orElse: () =>
          throw StateError('lucide_icons missing from package_config.json'),
    );
    var rootUri = Uri.parse(lucide['rootUri'] as String);
    // rootUri may be relative to the .dart_tool dir; resolve against it.
    if (!rootUri.isAbsolute) {
      rootUri = Uri.directory('${config.parent.path}/').resolveUri(rootUri);
    }
    // Ensure a trailing slash so `assets/lucide.ttf` resolves *under* the
    // package root rather than replacing the final path segment.
    final rootDir = rootUri.path.endsWith('/')
        ? rootUri
        : rootUri.replace(path: '${rootUri.path}/');
    final ttf = File.fromUri(rootDir.resolve('assets/lucide.ttf'));
    if (!ttf.existsSync()) {
      throw StateError('Lucide font asset not found: ${ttf.path}');
    }
    return ttf.path;
  }

  static Future<void> _loadFont(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('Missing bundled font for golden capture: $path');
    }
    final bytes = file.readAsBytesSync();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  /// The repository root, located by walking up until `version.yaml` (the
  /// single-source-of-truth marker) or `.git` is found.
  static Directory repoRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 10; i++) {
      if (File('${dir.path}/version.yaml').existsSync() ||
          Directory('${dir.path}/.git').existsSync()) {
        return dir;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return Directory.current;
  }

  /// Environment switch that sends captures to the tracked repo directory.
  ///
  /// A capture run rewrites files that are committed to the repository, so it
  /// is opt-in: a plain `flutter test` must leave the working tree clean.
  /// Mirrors the `SKOTIQ_LIVE_NETWORK` env gate already used by
  /// `skotiq_core` for its opt-in live-fetch test.
  static const captureEnvVar = 'SKOTIQ_CAPTURE_ASSETS';

  /// Whether this run writes the tracked assets, i.e.
  /// `SKOTIQ_CAPTURE_ASSETS=1` is set in the environment.
  static bool get capturesToRepo => Platform.environment[captureEnvVar] == '1';

  static Directory? _scratch;

  /// The capture output directory.
  ///
  /// Under [capturesToRepo] this is the committed `docs/design/goldens/`;
  /// otherwise it is a throwaway temp directory. The capture pipeline — render,
  /// rasterise, PNG-encode, write, assert — runs identically either way, so the
  /// tests keep proving a real non-empty image was produced without dirtying
  /// tracked files.
  static Directory goldensDir() {
    final dir = capturesToRepo
        ? Directory('${repoRoot().path}/docs/design/goldens')
        : (_scratch ??= Directory.systemTemp.createTempSync(
            'skotiq-goldens-',
          ));
    dir.createSync(recursive: true);
    return dir;
  }

  /// Pumps [child] under [theme] at a fixed logical [size], captures the
  /// `RepaintBoundary` to a PNG, and writes it to `<goldensDir>/<fileName>`.
  /// Returns the written file.
  ///
  /// [pixelRatio] scales the raster resolution (2.0 = crisp retina capture).
  static Future<File> capture(
    WidgetTester tester, {
    required String fileName,
    required ThemeData theme,
    required Widget child,
    required Size size,
    double pixelRatio = 2.0,
  }) async {
    await ensureFonts();

    final dpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = Size(size.width * dpr, size.height * dpr);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox.fromSize(size: size, child: child),
        ),
      ),
    );
    // Settle layout/paint without relying on animations completing (some
    // components run indeterminate/attention animations forever).
    await tester.pump(const Duration(milliseconds: 32));

    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    // toImage / toByteData are real async GPU+IO ops that never resolve under
    // the automated test binding's fake-async zone — capture inside runAsync
    // or the awaiting test hangs to the per-test timeout.
    final file = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) {
          throw StateError('PNG encode failed for golden capture: $fileName');
        }
        final out = File('${goldensDir().path}/$fileName');
        out.writeAsBytesSync(bytes.buffer.asUint8List());
        // ignore: avoid_print
        print(
          'Golden written: ${out.absolute.path} '
          '(${out.lengthSync()} bytes)',
        );
        return out;
      } finally {
        image.dispose();
      }
    });
    if (file == null) {
      throw StateError('Golden capture returned no file for: $fileName');
    }
    return file;
  }
}
