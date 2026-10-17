// Component C8b — guards + visual lock for the framing-screen HiPS layer wiring.
//
// What these pin (the composition contract this wiring is responsible for):
//
//   * GATING: when the layer is inactive for the current survey (feature flag
//     off, or the survey has no verified HiPS pyramid) the wiring contributes
//     NOTHING — no HiPS tile layer, no attribution badge — so the framing
//     canvas's existing single survey snapshot / starfield is the only
//     background, exactly the pre-HiPS behaviour. It must never throw resolving
//     an un-tile-capable survey.
//   * Z-ORDER / COMPOSITION: when active the wiring mounts the C8
//     [HipsAttributionBadge] as top chrome. The streamed mosaic itself
//     ([HipsTileLayer]) is composed INSIDE [FramingCanvas]'s own Stack — above
//     the single-cutout snapshot and UNDER the grid / FOV / equipment overlays —
//     so the imagery never hides the FOV reticle; this wiring therefore does NOT
//     mount the tile layer (only the attribution credit).
//   * ATTRIBUTION VISIBILITY (a licence requirement): the credit badge is shown
//     ONLY while HiPS imagery is actually on screen. No imagery resident → no
//     credit; imagery resident + a published credit → the credit is rendered.
//   * PLATFORM INDEPENDENCE: the wiring never reads any planetarium
//     rendering-platform provider; it is a Flutter-side framing-render-path layer
//     that works regardless of the rendering platform.
//
// A `flutter test --update-goldens` run also writes the visual lock golden and a
// human-inspectable sample under the repo-root `.hips_verify/` directory (the
// established HiPS verification convention), then prints its absolute path.
//
// Determinism: a fake fetcher (no network) is injected via
// [hipsTileFetcherProvider]; the resident snapshot is seeded directly (with an
// in-memory allsky image to make `hasAnyImagery` true) via the subclass-and-seed
// pattern on [hipsResidentTilesProvider]. No HTTP is ever issued.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/screens/framing/framing_hips_layer_wiring.dart';
import 'package:skotiq_app/screens/framing/widgets/hips_attribution_badge.dart';
import 'package:skotiq_app/screens/framing/widgets/hips_tile_layer.dart';
import 'package:skotiq_core/skotiq_core.dart';
// FramingPlateScale is an app->core src model (not surfaced through the public
// barrel) used in the seeded notifier's overridden requestViewport signature.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// Loader + cache are app->core service types shared with the framing tile layer;
// imported directly here (matching the C8 widget / framing painter convention)
// to seed a resident snapshot deterministically.
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';

import 'support/hips_fixture_render.dart' show ManualLoaderClock;

const FramingTarget _target = FramingTarget(
  name: 'NGC 7000',
  catalogId: 'NGC7000',
  raHours: 20.97,
  decDegrees: 44.33,
);

/// A published DSS-style `properties` document carrying an attribution credit
/// and copyright URL so the badge has something to render.
final HipsProperties _propsWithCredit = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
obs_copyright     = STScI Digitized Sky Survey
obs_copyright_url = https://archive.stsci.edu/dss/acknowledging.html
hips_creator      = CDS (Strasbourg)
''');

/// Seeds [FramingNotifier] with a known state (subclass-and-seed pattern), so
/// the wiring reads a fixed target/survey without DB/network wiring.
class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

/// A resident-tiles notifier seeded with a fixed snapshot (subclass-and-seed),
/// so the wiring sees a deterministic `hasAnyImagery` without driving the loader.
///
/// The C8 [HipsTileLayer] this wiring mounts drives the loader on a post-frame
/// callback (it calls [HipsResidentTilesNotifier.setSurvey] +
/// [HipsResidentTilesNotifier.requestViewport] once the survey `properties`
/// resolve). [setSurvey] hard-resets the loader (clearing the cache and
/// publishing an EMPTY snapshot), whose listener would otherwise overwrite the
/// seeded snapshot the moment the badge's credit would appear — silently wiping
/// the very `hasAnyImagery` state under test. Because this notifier exists to
/// PIN a fixed snapshot for the wiring/composition test (the loader's real
/// streaming behaviour is covered by the C6 async/LOD suites), it overrides the
/// loader-driving entry points to no-ops so the seed is authoritative for the
/// widget's lifetime.
class _SeededResidentNotifier extends HipsResidentTilesNotifier {
  _SeededResidentNotifier(super.loader, HipsResidentSnapshot seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }

  @override
  void setSurvey(SurveySource source) {
    // No-op: the seeded snapshot is authoritative for this composition test.
  }

  @override
  void requestViewport({
    required FramingPlateScale plateScale,
    required FramingTarget target,
    required ui.Size canvasSize,
    required double zoom,
    required ui.Offset pan,
    required double rotationDegrees,
    required HipsTileFormat format,
    required HipsProperties props,
  }) {
    // No-op: see [setSurvey]. The wiring test pins imagery via the seed.
  }

  @override
  void flushPending() {
    // No-op: nothing is driven through the loader in this composition test.
  }
}

/// A fetcher that never touches the network: [fetchProperties] returns a fixed,
/// already-parsed properties document so the attribution provider resolves
/// deterministically.
class _FakeFetcher extends HipsTileFetcher {
  final HipsProperties properties;
  _FakeFetcher(this.properties);

  @override
  Future<HipsProperties> fetchProperties(
    String baseUrl, {
    HipsFetchToken? token,
  }) async =>
      properties;
}

/// Builds a small solid [ui.Image] to stand in for a resident Allsky thumbnail,
/// which makes [HipsResidentSnapshot.hasAnyImagery] true.
Future<ui.Image> _solidImage(int w, int h, Color color) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  FramingState seededFraming({SurveySource source = SurveySource.dss2Red}) {
    return FramingState(
      target: _target,
      surveySource: source,
      previewFovDegrees: 0.5,
    );
  }

  /// A real loader built on a fake (no-network) fetcher + a tiny cache, driven by
  /// a [ManualLoaderClock] so any viewport push the mounted [HipsTileLayer] makes
  /// schedules a manually-advanced timer rather than a real `dart:async` [Timer]
  /// that would leak past tree disposal and trip the pending-timer assertion. The
  /// seeded notifier never advances the clock, so no fetch ever actually runs.
  HipsTileLoader makeLoader() => HipsTileLoader(
        cache: HipsTileCache(maxEntries: 8, maxBytes: 8 * 1024 * 1024),
        fetcher: _FakeFetcher(_propsWithCredit),
        clock: ManualLoaderClock(),
        ownsFetcher: true,
      );

  HipsResidentSnapshot snapshotWithImagery(ui.Image allsky) {
    return HipsResidentSnapshot(
      version: 1,
      selectedNorder: 3,
      primaryTiles: const [],
      fallbackTiles: const [],
      allsky: allsky,
      cacheSnapshot: HipsTileCacheSnapshot.empty,
      visibleSet: null,
      failures: const [],
    );
  }

  Widget hostUnder(List<Override> overrides) {
    return ProviderScope(
      overrides: [
        // Drive any loader the provider graph builds on a manually-advanced
        // clock so a viewport push never leaks a real pending Timer past tree
        // disposal (which would trip flutter_test's pending-timer assertion).
        hipsLoaderClockProvider.overrideWithValue(ManualLoaderClock()),
        ...overrides,
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: FramingHipsLayerWiring(),
          ),
        ),
      ),
    );
  }

  testWidgets(
      'inactive (feature off): wiring contributes nothing — no tile layer, no '
      'badge', (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededFraming())),
      hipsFramingEnabledProvider.overrideWith((ref) => false),
      hipsTileFetcherProvider.overrideWithValue(_FakeFetcher(_propsWithCredit)),
    ]));
    await tester.pump();

    expect(find.byType(HipsTileLayer), findsNothing,
        reason: 'Feature off → no HiPS tile layer mounted; the single survey '
            'snapshot underneath is the only background.');
    expect(find.byType(HipsAttributionBadge), findsNothing,
        reason: 'Feature off → no attribution badge.');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'un-tile-capable survey (no verified HiPS pyramid): wiring inactive, no '
      'throw', (tester) async {
    await tester.pumpWidget(hostUnder([
      framingProvider.overrideWith(
        (ref) => _SeededFramingNotifier(
          ref,
          seededFraming(source: SurveySource.sdss),
        ),
      ),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider.overrideWithValue(_FakeFetcher(_propsWithCredit)),
    ]));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'A survey with no verified HiPS base URL must deactivate the '
            'wiring cleanly, not throw resolving its address.');
    expect(find.byType(HipsTileLayer), findsNothing);
    expect(find.byType(HipsAttributionBadge), findsNothing);
  });

  testWidgets(
      'active but no imagery resident: attribution badge mounted but hidden '
      '(licence: credit only while imagery is shown)', (tester) async {
    final loader = makeLoader();
    addTearDown(loader.dispose);

    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededFraming())),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider.overrideWithValue(_FakeFetcher(_propsWithCredit)),
      hipsResidentTilesProvider.overrideWith(
        (ref) => _SeededResidentNotifier(loader, HipsResidentSnapshot.empty),
      ),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // The wiring mounts only the attribution badge; the streamed tile mosaic is
    // composed inside FramingCanvas (not present in this isolated wiring host).
    expect(find.byType(HipsTileLayer), findsNothing,
        reason:
            'The wiring no longer mounts the tile layer — that lives inside '
            'FramingCanvas, under the FOV overlays.');
    expect(find.byType(HipsAttributionBadge), findsOneWidget,
        reason: 'Active → the attribution badge is mounted (it gates its own '
            'visibility on resident imagery).');
    // The badge widget is built but, with no imagery + visible:false, it renders
    // nothing (SizedBox.shrink). The credit text must therefore be absent.
    expect(find.text('STScI Digitized Sky Survey'), findsNothing,
        reason: 'No imagery resident → the attribution credit must not show.');
  });

  testWidgets(
      'active + imagery resident + published credit: attribution credit is '
      'rendered', (tester) async {
    // `_solidImage` rasterises via Picture.toImage, whose engine callback only
    // fires on the real event loop — so build it inside runAsync, never directly
    // in the testWidgets FakeAsync zone (where the future would hang forever).
    final allsky = (await tester.runAsync(
      () => _solidImage(32, 32, const Color(0xFF335577)),
    ))!;
    addTearDown(allsky.dispose);
    final loader = makeLoader();
    addTearDown(loader.dispose);

    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededFraming())),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider.overrideWithValue(_FakeFetcher(_propsWithCredit)),
      hipsResidentTilesProvider.overrideWith(
        (ref) => _SeededResidentNotifier(loader, snapshotWithImagery(allsky)),
      ),
    ]));
    // Pump twice: first frame builds, the attribution FutureProvider resolves on
    // the next microtask so the badge sees the credit.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(HipsAttributionBadge), findsOneWidget);
    expect(find.text('STScI Digitized Sky Survey'), findsOneWidget,
        reason: 'Imagery resident + a published credit → the survey copyright '
            'must be displayed (the HiPS attribution licence requirement).');
  });

  testWidgets(
      'golden + sample: composed badge over imagery renders the survey credit',
      tags: 'golden', (tester) async {
    final allsky = (await tester.runAsync(
      () => _solidImage(32, 32, const Color(0xFF335577)),
    ))!;
    addTearDown(allsky.dispose);
    final loader = makeLoader();
    addTearDown(loader.dispose);

    // Pin the surface so the golden is deterministic across hosts (DPR=1).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(hostUnder([
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededFraming())),
      hipsFramingEnabledProvider.overrideWith((ref) => true),
      hipsTileFetcherProvider.overrideWithValue(_FakeFetcher(_propsWithCredit)),
      hipsResidentTilesProvider.overrideWith(
        (ref) => _SeededResidentNotifier(loader, snapshotWithImagery(allsky)),
      ),
    ]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    await expectLater(
      find.byType(FramingHipsLayerWiring),
      matchesGoldenFile('goldens/framing_hips_layer_wiring.png'),
    );

    // Also write a human-inspectable sample under the repo-root .hips_verify/.
    // Capture + PNG-encode on the real event loop (runAsync): the layer-tree
    // toImage/toByteData callbacks fire on the engine, not in FakeAsync.
    final pngBytes = await tester.runAsync(() async {
      final image = await _captureSample(tester);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes;
    });
    expect(pngBytes, isNotNull);

    final verifyDir = Directory(_hipsVerifyDirPath());
    verifyDir.createSync(recursive: true);
    final samplePath =
        '${verifyDir.path}${Platform.pathSeparator}framing_hips_layer_wiring.png';
    File(samplePath).writeAsBytesSync(pngBytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('C8b sample written: ${File(samplePath).absolute.path}');
  });
}

/// Captures the nearest repaint boundary enclosing the [FramingHipsLayerWiring]
/// subtree to a [ui.Image] for the human-inspectable sample.
Future<ui.Image> _captureSample(WidgetTester tester) async {
  final element = find.byType(FramingHipsLayerWiring).evaluate().single;
  RenderObject? node = element.renderObject;
  while (node != null && node is! RenderRepaintBoundary) {
    node = node.parent;
  }
  expect(node, isA<RenderRepaintBoundary>(),
      reason: 'A repaint boundary must enclose the wiring subtree to capture '
          'the sample image.');
  return (node! as RenderRepaintBoundary).toImage(pixelRatio: 1.0);
}

/// Repo-root `.hips_verify/` path (four levels up from this test file's package).
String _hipsVerifyDirPath() {
  // CWD during `flutter test` is the package dir (packages/skotiq_app); the
  // repo root is two levels up.
  final cwd = Directory.current.path;
  final sep = Platform.pathSeparator;
  return '$cwd$sep..$sep..$sep.hips_verify';
}
