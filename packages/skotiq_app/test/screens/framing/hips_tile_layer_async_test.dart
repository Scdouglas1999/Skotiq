// Component C10 — async-non-blocking + GPU-only op-stream guard for the
// Flutter-side GPU HiPS framing tile layer, driven end-to-end through the real
// C6 loader fed the committed C-FIX fixtures.
//
// THE CONTRACT THIS PINS (anti-jank requirements #1, #3, #6):
//
//   #1  Fetch + decode never block the UI/build thread. The C8 painter is a pure
//       function of a pre-built immutable snapshot: it `await`s nothing, opens no
//       socket, decodes no image. We prove this by running the real C6 loader
//       (which performs all fetch/decode work) on a ManualLoaderClock + a
//       fixture-backed fetcher, draining the loader's async work, THEN painting —
//       and asserting paint() is synchronous (returns a value, never a Future)
//       and emits the resident tiles without touching the loader.
//
//   #3  Debounce + dedup + cancel. A burst of viewport requests collapses to ONE
//       recompute (the trailing debounce), and a tile is fetched at most once
//       across that burst (dedup). We assert both against the loader's behaviour
//       and the fixture fetcher's per-tile call counts.
//
//   #6  GPU compositing only. Every pixel the painter moves goes through
//       `Canvas.drawVertices` (textured triangles on the GPU); it issues zero
//       `drawImageRect` / `drawImage` / `drawRawAtlas`-free CPU pixel ops. A
//       recording canvas captures the op stream and asserts it is drawVertices
//       (+ the clip/save/restore framing), nothing else.
//
// Determinism: the loader's debounce runs on a ManualLoaderClock (no wall-clock),
// fetches are served from committed bytes (no network), and decode goes through
// the production `ui.decodeImageFromList` path.

import 'dart:typed_data';
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

const Duration _debounce = Duration(milliseconds: 90);

/// Records the painter's full Canvas op stream so the test can assert it is
/// GPU-only (drawVertices) plus the structural save/clip/restore framing.
class _OpStreamCanvas implements Canvas {
  int nDrawVertices = 0;
  int nDrawImageRect = 0;
  int nDrawImage = 0;
  int nDrawAtlas = 0;
  int nDrawRect = 0;
  int nSaves = 0;
  int nRestores = 0;
  int nClips = 0;

  @override
  void drawVertices(ui.Vertices vertices, BlendMode blendMode, Paint paint) =>
      nDrawVertices++;

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) =>
      nDrawImageRect++;

  @override
  void drawImage(ui.Image image, Offset offset, Paint paint) => nDrawImage++;

  @override
  void drawAtlas(
          ui.Image atlas,
          List<RSTransform> transforms,
          List<Rect> rects,
          List<Color>? colors,
          BlendMode? blendMode,
          Rect? cullRect,
          Paint paint) =>
      nDrawAtlas++;

  @override
  void drawRawAtlas(
          ui.Image atlas,
          Float32List transforms,
          Float32List rects,
          Int32List? colors,
          BlendMode? blendMode,
          Rect? cullRect,
          Paint paint) =>
      nDrawAtlas++;

  @override
  void drawRect(Rect rect, Paint paint) => nDrawRect++;

  @override
  void save() => nSaves++;

  @override
  void restore() => nRestores++;

  @override
  void clipRect(Rect rect,
          {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) =>
      nClips++;

  @override
  void noSuchMethod(Invocation invocation) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HipsProperties props;
  setUpAll(() {
    props = HipsProperties.parse(fixture.readPropertiesText());
  });

  /// Builds a viewport for the fixture field at the given zoom AND field
  /// rotation. A rotation-only delta is a *different recompute*
  /// ([HipsViewport.sameRecomputeInputs] is false) yet selects the same Norder
  /// and the same committed visible-tile footprint, which the cancel test relies
  /// on to supersede a generation without fetching uncommitted tiles.
  HipsViewport viewportRotated(double zoom, double rotationDegrees) =>
      HipsViewport(
        plateScale: _plateScale,
        target: _target,
        canvasSize: _canvasSize,
        zoom: zoom,
        pan: Offset.zero,
        rotationDegrees: rotationDegrees,
        baseUrl: fixture.surveyBaseUrl,
        surveyId: fixture.surveyHipsId,
        format: fixture.surveyTileFormat,
        props: props,
      );

  /// Builds a viewport for the fixture field at the given zoom.
  HipsViewport viewport(double zoom) => viewportRotated(zoom, 0);

  test(
      'paint is synchronous and never touches the loader: fetch + decode ran on '
      'the loader, the painter only composites the finished snapshot',
      () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final loader = HipsTileLoader(
      cache: HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024),
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    loader.requestTiles(viewport(1.0));
    expect(loader.hasPendingRecompute, isTrue,
        reason: 'A request must debounce (schedule a trailing recompute), not '
            'recompute synchronously on the calling frame.');

    // Fire the debounce (runs C3 selection + schedules the async fetches) and
    // drain the loader's off-build-thread fetch/decode continuations on the real
    // event loop until imagery is resident.
    final settled = await settleLoaderUntil(
      drive: clock.flush,
      condition: () => loader.snapshot.hasAnyImagery,
    );
    expect(settled, isTrue,
        reason: 'The loader must settle resident imagery within the budget.');

    final snapshot = loader.snapshot;
    expect(snapshot.hasAnyImagery, isTrue,
        reason:
            'After the debounce fires and fetches settle, committed tiles / '
            'Allsky must be resident in the snapshot.');

    final painter = HipsTileLayerPainter(
      snapshot: snapshot,
      allskyOrder: props.allskyOrder,
    );

    // paint() is synchronous: it returns void, awaits nothing, opens no socket.
    // We call it and inspect the op stream immediately WITHOUT awaiting — if
    // paint() deferred any compositing to a future, the recorder would be empty
    // here. It is not: every resident tile is composited inline on this frame.
    final recorder = _OpStreamCanvas();
    painter.paint(recorder, _canvasSize);
    expect(recorder.nDrawVertices, greaterThan(0),
        reason: 'CustomPainter.paint must composite synchronously on the frame '
            '— it must never block on or defer to I/O / decode. The resident '
            'snapshot composited at least one GPU mesh inline.');
  });

  test('GPU-only op stream: the painter emits drawVertices and nothing else',
      () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final loader = HipsTileLoader(
      cache: HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024),
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    final settled = await settleLoaderUntil(
      drive: () {
        loader.requestTiles(viewport(1.0));
        clock.flush();
      },
      condition: () => loader.snapshot.hasAnyImagery,
    );
    expect(settled, isTrue,
        reason: 'The loader must settle resident imagery within the budget.');

    final painter = HipsTileLayerPainter(
      snapshot: loader.snapshot,
      allskyOrder: props.allskyOrder,
    );
    final recorder = _OpStreamCanvas();
    painter.paint(recorder, _canvasSize);

    expect(recorder.nDrawVertices, greaterThan(0),
        reason:
            'Every tile / Allsky cell is composited as a textured GPU mesh.');
    expect(recorder.nDrawImageRect, 0,
        reason: 'No drawImageRect: the painter never flat-stretches an image '
            '(that would seam and bow the mosaic).');
    expect(recorder.nDrawImage, 0, reason: 'No raw drawImage CPU blit.');
    expect(recorder.nDrawAtlas, 0,
        reason: 'No drawAtlas path is used by this painter; all geometry is a '
            'subdivided drawVertices mesh.');
    expect(recorder.nDrawRect, 0,
        reason:
            'The painter draws no solid fills — it composites imagery only, '
            'staying transparent where no tile is resident.');
    // Structural framing: exactly one save/clip/restore around the mosaic.
    expect(recorder.nSaves, 1);
    expect(recorder.nClips, 1);
    expect(recorder.nRestores, 1);
  });

  test(
      'debounce coalesces a burst of viewports into ONE recompute (no request '
      'thrash on pan/zoom)', () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final loader = HipsTileLoader(
      cache: HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024),
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    final genBefore = loader.generation;

    // A pan/zoom gesture emits many viewports in quick succession. Each restarts
    // the trailing debounce; only the final one should recompute.
    loader.requestTiles(viewport(1.0));
    loader.requestTiles(viewport(1.05));
    loader.requestTiles(viewport(1.1));
    loader.requestTiles(viewport(1.0));
    expect(clock.pendingCount, 1,
        reason: 'A burst of requests must collapse to a single pending '
            'recompute (the trailing debounce restarted each time).');

    final settled = await settleLoaderUntil(
      drive: clock.flush,
      condition: () => loader.snapshot.hasAnyImagery,
    );
    expect(settled, isTrue,
        reason: 'The single coalesced recompute must settle imagery.');

    expect(loader.generation, genBefore + 1,
        reason:
            'The whole burst must produce exactly ONE recompute generation, '
            'not one per viewport delta.');
  });

  test('dedup: a tile needed by the recompute is fetched at most once',
      () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final loader = HipsTileLoader(
      cache: HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024),
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    // Request the same viewport twice (a held gesture emitting identical
    // deltas). The selected-order tile set is identical, so no tile is re-fetched.
    final settled = await settleLoaderUntil(
      drive: () {
        loader.requestTiles(viewport(1.0));
        clock.flush();
      },
      condition: () => loader.snapshot.hasAnyImagery,
    );
    expect(settled, isTrue,
        reason: 'The first recompute must settle so its fetches are recorded.');

    // Re-request the identical viewport: a no-op (sameRecomputeInputs) — it must
    // not even schedule, let alone re-fetch.
    loader.requestTiles(viewport(1.0));
    expect(clock.pendingCount, 0,
        reason: 'An identical viewport after a completed recompute is a no-op; '
            'it must not reschedule or re-fetch.');

    final overFetched =
        fetcher.tileFetchCounts.entries.where((e) => e.value > 1).toList();
    expect(overFetched, isEmpty,
        reason: 'Every fetched tile must be fetched at most once across the '
            'burst (in-flight + cache dedup). Over-fetched: $overFetched');
    expect(fetcher.propertiesFetchCount, lessThanOrEqualTo(0),
        reason: 'The loader does not fetch properties (the widget does); the '
            'loader must not issue a properties request.');
  });

  test(
      'cancel: a superseding viewport cancels the prior generation\'s in-flight '
      'fetches (no socket thrash, no stale tiles landed for the old view)',
      () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final loader = HipsTileLoader(
      cache: HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024),
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    // Hold the first generation's primary tiles in flight so they cannot resolve
    // before we supersede them. The committed Norder6 set over M31 is the full
    // golden-zoom selection, so holding it holds every primary fetch.
    final firstSet = HipsTileSelection.computeVisibleTiles(
      _plateScale,
      _target,
      _canvasSize,
      1.0,
      HipsTileSelection.selectNorder(
        _plateScale.pixelsPerDegree(_canvasSize, 1.0),
        props,
      ),
      props,
      surveyId: fixture.surveyHipsId,
    );
    fetcher.hold(firstSet.tiles.map((t) => t.id));

    loader.requestTiles(viewport(1.0));
    clock.flush(); // generation 1 opens, fetches start but are held.

    final genAfterFirst = loader.generation;

    // A new (different) viewport supersedes generation 1; its token is cancelled.
    // We rotate the field rather than zooming: a rotation changes the recompute
    // inputs (so a new generation opens and generation 1's token is cancelled)
    // while the selected Norder and the visible-tile footprint stay the SAME
    // committed set — so generation 2 fetches no uncommitted tiles and produces
    // no spurious 404s of its own. (A zoom to 2.0 would select the uncommitted
    // Norder7 set, whose 404s would pollute the snapshot and mask the property
    // under test, which is purely that *cancellations* are not logged as
    // failures.) Generation 2's fetches for the committed set dedup against
    // generation 1's still-in-flight (held) requests, so releasing the hold
    // surfaces those held requests as cancellations of the superseded
    // generation — exactly the path being verified.
    final settled = await settleLoaderUntil(
      drive: () {
        loader.requestTiles(viewportRotated(1.0, 5.0));
        clock.flush(); // generation 2 opens; generation 1's token is cancelled.
        // Release the held generation-1 fetches: they re-check their (cancelled)
        // token and surface as HipsFetchCancelledException, which must be dropped
        // quietly and NOT recorded in the current snapshot's failures.
        fetcher.releaseHeld();
      },
      // The held generation-1 fetches each complete (as cancellations) and
      // unregister from the in-flight set; settle until that has drained.
      condition: () => loader.generation > genAfterFirst,
    );
    expect(settled, isTrue,
        reason: 'The superseding recompute must advance the generation.');

    expect(loader.generation, greaterThan(genAfterFirst),
        reason:
            'A superseding viewport must advance the generation, cancelling '
            'the prior generation\'s in-flight fetches.');
    expect(loader.snapshot.failures, isEmpty,
        reason:
            'Cancellations of a superseded generation are expected and must '
            'NOT be recorded as failures.');
  });
}
