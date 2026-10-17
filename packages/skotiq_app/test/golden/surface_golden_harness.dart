import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Capture support for the key-surface design goldens.
///
/// Mirrors the skotiq_ui golden harness: it loads the real bundled fonts so
/// rasterised PNGs render the shipped typefaces (not Ahem boxes), then captures
/// a `RepaintBoundary` of a fully-built surface to a PNG written into
/// `docs/design/goldens/`. These are review artifacts for the lead engineer, not
/// pixel-diff guards — the test bodies assert only that a real, non-empty image
/// was produced.
///
/// Writing the tracked PNGs (and the `assets/screenshots/` set) is OPT-IN: set
/// `SKOTIQ_CAPTURE_ASSETS=1` to refresh them. Without it the capture still
/// runs in full but lands in a temp directory, so a plain `flutter test` leaves
/// the working tree clean. See `docs/testing/golden-tests.md`.
abstract final class SurfaceGoldenHarness {
  SurfaceGoldenHarness._();

  static bool _fontsLoaded = false;

  static Future<void> ensureFonts() async {
    if (_fontsLoaded) return;
    final fontsDir = '${repoRoot().path}/packages/skotiq_ui/assets/fonts';
    await _loadFont('HankenGrotesk', '$fontsDir/HankenGrotesk-VF.ttf');
    await _loadFont('SplineSansMono', '$fontsDir/SplineSansMono-VF.ttf');
    // Lucide glyph font (family "Lucide", package "lucide_icons") so icons in
    // captured surfaces render as real glyphs, not tofu boxes.
    await _loadFont('packages/lucide_icons/Lucide', resolveLucideTtf());
    _fontsLoaded = true;
  }

  static bool _captureFontsLoaded = false;

  /// [ensureFonts] plus MaterialIcons, which the app gets from its own bundle
  /// (`uses-material-design: true`) but `flutter test` does not load. Without
  /// it the Material glyphs users genuinely see — a dropdown caret, say — draw
  /// as tofu boxes, which is what reached the published screenshots.
  ///
  /// Deliberately NOT part of [ensureFonts]: the pixel-diff goldens were
  /// captured without this face, and adding glyphs to the shared path would
  /// invalidate every one of those baselines. Only the public-screenshot
  /// capture, which asserts nothing about pixels, opts in.
  ///
  /// Emoji are a known gap. The profile icon row offers telescope, moon,
  /// ringed planet, star and camera as literal emoji, and they still capture
  /// as boxes: a font registered through `loadFontFromList` is reachable by
  /// family name, and nothing names a family for those strings, so the
  /// renderer never reaches it through the fallback chain. Fixing it needs the
  /// icons to stop being emoji, not another font here.
  static Future<void> ensureCaptureFonts() async {
    await ensureFonts();
    if (_captureFontsLoaded) return;
    final materialIcons = resolveMaterialIconsOtf();
    if (materialIcons != null) {
      await _loadFont('MaterialIcons', materialIcons);
    }
    _captureFontsLoaded = true;
  }

  /// Locates `MaterialIcons-Regular.otf` in the Flutter SDK cache, resolved
  /// from the running `dart` executable. Returns null rather than throwing:
  /// the icon font is a nicety for the captures, not a correctness gate.
  static String? resolveMaterialIconsOtf() {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 6; i++) {
      final candidate = File(
        '${dir.path}/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (candidate.existsSync()) return candidate.path;
      final nested = File(
        '${dir.path}/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
      );
      if (nested.existsSync()) return nested.path;
      dir = dir.parent;
    }
    return null;
  }

  /// Resolves the absolute path to the bundled Lucide icon font via the test
  /// package's `.dart_tool/package_config.json`. Fails loud if unresolvable.
  static String resolveLucideTtf() {
    final config =
        File('${Directory.current.path}/.dart_tool/package_config.json');
    if (!config.existsSync()) {
      throw StateError('package_config.json not found: ${config.path}');
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
    if (!rootUri.isAbsolute) {
      rootUri = Uri.directory('${config.parent.path}/').resolveUri(rootUri);
    }
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
  static Directory? _screenshotScratch;

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
        : (_scratch ??= Directory.systemTemp.createTempSync('skotiq-goldens-'));
    dir.createSync(recursive: true);
    return dir;
  }

  /// The public-screenshot output directory, gated exactly like [goldensDir]:
  /// the committed `assets/screenshots/` only under [capturesToRepo], a
  /// throwaway temp directory otherwise.
  static Directory screenshotsDir() {
    final dir = capturesToRepo
        ? Directory('${repoRoot().path}/assets/screenshots')
        : (_screenshotScratch ??=
            Directory.systemTemp.createTempSync('skotiq-screenshots-'));
    dir.createSync(recursive: true);
    return dir;
  }

  /// Captures whatever is currently mounted under [boundaryKey] to
  /// `<goldensDir>/<fileName>` and returns the written file.
  ///
  /// `RenderRepaintBoundary.toImage` and `Image.toByteData` are real
  /// (non-fake) async GPU/IO operations. Under the automated test binding's
  /// fake-async zone they never resolve — so the capture MUST run inside
  /// [WidgetTester.runAsync], otherwise the awaiting test hangs until the
  /// per-test timeout. (The PNG still gets written by the worker, which is why
  /// earlier runs produced images yet each test then timed out.)
  static Future<File> captureBoundary(
    WidgetTester tester,
    GlobalKey boundaryKey, {
    required String fileName,
    double pixelRatio = 2.0,
  }) async {
    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
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
        print('Golden written: ${out.absolute.path} '
            '(${out.lengthSync()} bytes)');
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
