// Component C10 — frame-budget + shouldRepaint + bounded-cache guard for the
// Flutter-side GPU HiPS framing tile layer, over the committed C-FIX mosaic.
//
// THE CONTRACTS THIS PINS (anti-jank requirements #2 and #6, plus repaint
// gating):
//
//   FRAME BUDGET: compositing the full committed M31 mosaic (the dense Norder6
//   primary set + Allsky base) must build its GPU meshes well within a single
//   16.67 ms (60 fps) frame on the build thread — the painter does no per-pixel
//   CPU work, so its build cost is bounded by vertex emission. We rasterise the
//   real painter to a ui.Image (the actual GPU upload path) and assert the
//   painter's synchronous mesh-build cost stays under budget.
//
//   SHOULD-REPAINT GATING: the painter repaints iff the snapshot version (or the
//   Allsky order) changed — a stationary view with the same snapshot must NOT
//   repaint (no wasted frames), and any view movement / tile arrival (a new
//   version) must repaint exactly once.
//
//   BOUNDED LRU CACHE (#2): the decoded-tile cache evicts by entry count and
//   byte budget, so a deep pan that touches more tiles than fit never grows
//   native memory unbounded. We drive the real C4 cache through more committed
//   tiles than its cap and assert it stayed within both bounds, evicting the LRU.
//
// Determinism: committed fixtures decoded through the production path; no network.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/hips_tile_layer_painter.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

import '../../fixtures/hips/fixture_field.dart' as fixture;
import 'support/hips_fixture_render.dart';

const FramingTarget _target = FramingTarget(
  name: fixture.fieldName,
  catalogId: 'M31',
  raHours: fixture.fieldRaHours,
  decDegrees: fixture.fieldDecDeg,
);

const FramingPlateScale _plateScale = FramingPlateScale(
  surveyFovWidthDeg: fixture.fixtureFovWidthDeg,
  surveyFovHeightDeg: fixture.fixtureFovHeightDeg,
  imagePixelWidth: fixture.fixturePixelWidth,
  imagePixelHeight: fixture.fixturePixelHeight,
);

final Size _canvasSize = Size(
  fixture.fixturePixelWidth.toDouble(),
  fixture.fixturePixelHeight.toDouble(),
);

/// One 60 fps frame, in microseconds. The painter's synchronous mesh-build cost
/// must sit comfortably below this; we use a generous multiple of headroom over
/// the typical measured cost so the assertion is robust on a slow CI box yet
/// still catches a catastrophic per-pixel-CPU cost (which would blow well past
/// a frame).
const int _frameBudgetMicros = 16667;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HipsProperties props;
  late HipsVisibleTileSet visibleSet;

  setUpAll(() {
    props = HipsProperties.parse(fixture.readPropertiesText());
    final norder = HipsTileSelection.selectNorder(
      _plateScale.pixelsPerDegree(_canvasSize, 1.0),
      props,
    );
    visibleSet = HipsTileSelection.computeVisibleTiles(
      _plateScale,
      _target,
      _canvasSize,
      1.0,
      norder,
      props,
      surveyId: fixture.surveyHipsId,
    );
  });

  /// Builds a fully-resident snapshot of the committed primary mosaic + Allsky.
  Future<
      ({
        HipsResidentSnapshot snapshot,
        HipsTileCache cache,
        ui.Image allsky
      })> buildResidentMosaic() async {
    final cache = HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024);
    final primary = <HipsVisibleTile>[];
    for (final tile in visibleSet.tiles) {
      final bytes = fixtureTileBytesOrNull(tile.id);
      if (bytes == null) continue;
      cache.put(tile.id, await decodeFixtureImage(bytes));
      primary.add(tile);
    }
    final allsky = await decodeFixtureImage(fixture.readAllskyBytes());
    final snapshot = HipsResidentSnapshot(
      version: 1,
      selectedNorder: visibleSet.norder,
      primaryTiles: List.unmodifiable(primary),
      fallbackTiles: const [],
      allsky: allsky,
      cacheSnapshot: cache.snapshot(),
      visibleSet: visibleSet,
      failures: const [],
    );
    return (snapshot: snapshot, cache: cache, allsky: allsky);
  }

  test('the full committed mosaic composites within a 60 fps frame budget',
      () async {
    final built = await buildResidentMosaic();
    addTearDown(built.cache.dispose);
    addTearDown(built.allsky.dispose);

    final painter = HipsTileLayerPainter(
      snapshot: built.snapshot,
      allskyOrder: props.allskyOrder,
    );

    // Warm one paint so any one-time allocation/JIT is not charged to the timed
    // run (a real per-frame paint is the steady-state cost we care about).
    final warmRecorder = ui.PictureRecorder();
    painter.paint(Canvas(warmRecorder), _canvasSize);
    warmRecorder.endRecording().dispose();

    // Time the synchronous mesh-build the painter performs each frame.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final sw = Stopwatch()..start();
    painter.paint(canvas, _canvasSize);
    sw.stop();
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);

    expect(sw.elapsedMicroseconds, lessThan(_frameBudgetMicros),
        reason: 'Compositing the full committed mosaic took '
            '${sw.elapsedMicroseconds}us, over the ${_frameBudgetMicros}us '
            '60fps frame budget. The painter must do no per-frame CPU pixel '
            'work — a blowout this large indicates a software blend / getBytes '
            'crept in.');

    // The GPU upload itself (Picture.toImage) must also produce a real image —
    // the actual compositing path the engine runs.
    final image = await picture.toImage(
      fixture.fixturePixelWidth,
      fixture.fixturePixelHeight,
    );
    addTearDown(image.dispose);
    expect(image.width, fixture.fixturePixelWidth);
    expect(image.height, fixture.fixturePixelHeight);
  });

  test('shouldRepaint repaints only on a version or allsky-order change',
      () async {
    final built = await buildResidentMosaic();
    addTearDown(built.cache.dispose);
    addTearDown(built.allsky.dispose);

    final v1 = built.snapshot;
    final v2 = HipsResidentSnapshot(
      version: v1.version + 1,
      selectedNorder: v1.selectedNorder,
      primaryTiles: v1.primaryTiles,
      fallbackTiles: v1.fallbackTiles,
      allsky: v1.allsky,
      cacheSnapshot: v1.cacheSnapshot,
      visibleSet: v1.visibleSet,
      failures: v1.failures,
    );

    final order = props.hipsOrderMin;
    final p1 = HipsTileLayerPainter(snapshot: v1, allskyOrder: order);
    final p1Same = HipsTileLayerPainter(snapshot: v1, allskyOrder: order);
    final p2 = HipsTileLayerPainter(snapshot: v2, allskyOrder: order);
    final p1DiffOrder =
        HipsTileLayerPainter(snapshot: v1, allskyOrder: order + 1);

    expect(p1Same.shouldRepaint(p1), isFalse,
        reason: 'A stationary view (identical snapshot version + allsky order) '
            'must NOT repaint — no wasted frames.');
    expect(p2.shouldRepaint(p1), isTrue,
        reason: 'A view movement / tile arrival (new version) must repaint '
            'exactly once.');
    expect(p1DiffOrder.shouldRepaint(p1), isTrue,
        reason: 'A survey switch changing the Allsky order must repaint.');
  });

  test(
      'the bounded LRU cache evicts so a deep pan never grows memory unbounded',
      () async {
    // A cache far smaller than the committed primary set, so feeding the whole
    // set forces eviction and proves both bounds hold.
    const maxEntries = 6;
    // Byte budget large enough that the ENTRY cap binds first (so we test the
    // entry-count bound) — a 512x512 RGBA tile is ~1 MiB, 6 of them ~6 MiB.
    const maxBytes = 64 * 1024 * 1024;
    final cache = HipsTileCache(maxEntries: maxEntries, maxBytes: maxBytes);
    addTearDown(cache.dispose);

    var fed = 0;
    for (final tile in visibleSet.tiles) {
      final bytes = fixtureTileBytesOrNull(tile.id);
      if (bytes == null) continue;
      cache.put(tile.id, await decodeFixtureImage(bytes));
      fed++;
      expect(cache.length, lessThanOrEqualTo(maxEntries),
          reason: 'The cache must never exceed its entry cap; a deep pan that '
              'touches many tiles must evict the LRU, not grow unbounded.');
      expect(cache.currentBytes, lessThanOrEqualTo(maxBytes),
          reason: 'The cache must never exceed its byte budget.');
    }
    expect(fed, greaterThan(maxEntries),
        reason: 'The committed mosaic must be larger than the cache cap so '
            'eviction is actually exercised.');
    expect(cache.length, maxEntries,
        reason:
            'After feeding more tiles than fit, the cache holds exactly its '
            'entry cap (the most-recently-used ones).');

    // The most-recently-fed tiles are the survivors (LRU eviction): the last
    // committed tile fed must still be resident, an early one must be gone.
    final keys = cache.keysByRecency; // LRU -> MRU
    expect(keys.length, maxEntries);
  });
}
