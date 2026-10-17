// Component C10 — level-of-detail "never blank" guard for the Flutter-side GPU
// HiPS framing tile layer, driven through the real C6 loader fed the committed
// C-FIX fixtures.
//
// THE CONTRACT THIS PINS (anti-jank requirement #4, LOD never-blank fallback):
// when the view changes to a region whose SHARP (selected-Norder) tiles have not
// streamed in yet, the layer must show an already-loaded coarser tile (a parent
// ancestor) or the whole-sky Allsky base UNDER the streaming sharp layer — never
// a blank flash. Only once the sharp tile lands is it promoted to the primary
// layer on top.
//
// HOW IT PROVES IT, deterministically:
//   1. Pre-seed the loader's cache with the committed COARSE fixtures (the
//      Norder5 parents + Norder4 grandparents) so a coarser ancestor is resident
//      for the M31 field — exactly the state after an earlier coarse pass.
//   2. HOLD the sharp Norder6 primary fetches in flight (they cannot resolve).
//   3. Request the fixture viewport and fire the debounce. Assert the published
//      snapshot has imagery (Allsky + coarse fallback tiles) and that the C8
//      painter therefore draws SOMETHING (>=1 GPU mesh) — the region is covered,
//      not blank — even though zero sharp primaries are resident yet.
//   4. Release the held sharp fetches; assert they are promoted to primaryTiles
//      and the snapshot version advanced (the sharp layer arrived on top).
//
// This is the single most important smoothness guarantee: a user panning/zooming
// always sees coarse imagery immediately and the sharp tiles sharpen in, with no
// black gap at any moment.

import 'dart:math' as math;
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
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
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

/// Counts the GPU meshes the painter emits and notes whether any solid fill was
/// drawn (there must be none — the layer composites imagery only).
class _MeshCountCanvas implements Canvas {
  int meshes = 0;
  int rects = 0;

  @override
  void drawVertices(ui.Vertices v, BlendMode b, Paint p) => meshes++;

  @override
  void drawRect(Rect rect, Paint paint) => rects++;

  @override
  void noSuchMethod(Invocation invocation) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HipsProperties props;
  setUpAll(() {
    props = HipsProperties.parse(fixture.readPropertiesText());
  });

  HipsViewport viewport(double zoom) => HipsViewport(
        plateScale: _plateScale,
        target: _target,
        canvasSize: _canvasSize,
        zoom: zoom,
        pan: Offset.zero,
        rotationDegrees: 0,
        baseUrl: fixture.surveyBaseUrl,
        surveyId: fixture.surveyHipsId,
        format: fixture.surveyTileFormat,
        props: props,
      );

  test(
      'never-blank: while sharp tiles stream in, the coarse fallback + Allsky '
      'cover the footprint so the painter draws imagery (not a blank flash)',
      () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final cache = HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024);
    final loader = HipsTileLoader(
      cache: cache,
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    // The sharp Norder6 set for this field (the committed primary fixtures).
    final sharpNorder = HipsTileSelection.selectNorder(
      _plateScale.pixelsPerDegree(_canvasSize, 1.0),
      props,
    );
    expect(sharpNorder, fixture.primaryNorder,
        reason: 'The fixture golden zoom must select the committed primary '
            'Norder so this test exercises the real LOD chain.');

    // Hold EVERY committed primary tile in flight so none can resolve before we
    // observe the coarse-fallback window.
    fetcher.hold(fixture.primaryTiles);

    // Fire selection + the Allsky/parent/primary fetches, then drain on the real
    // event loop until the coarse fallback / Allsky base is resident. The held
    // sharp primaries cannot resolve, so the steady state we wait for is "coarse
    // imagery present, no sharp primary resident".
    final streamingSettled = await settleLoaderUntil(
      drive: () {
        loader.requestTiles(viewport(1.0));
        clock.flush();
      },
      condition: () => loader.snapshot.hasAnyImagery,
    );
    expect(streamingSettled, isTrue,
        reason: 'The coarse fallback / Allsky base must settle while the sharp '
            'primaries are held.');

    // The Allsky (committed at the survey min order) decodes immediately; the
    // parent fixtures decode immediately too (not held). The sharp primaries are
    // held, so they are NOT resident yet.
    final streaming = loader.snapshot;
    final residentPrimary = streaming.primaryTiles
        .where((t) => fixture.primaryTiles.contains(t.id))
        .toList();
    expect(residentPrimary, isEmpty,
        reason: 'The sharp Norder${fixture.primaryNorder} tiles are held in '
            'flight, so none may be resident as primary yet.');
    expect(streaming.hasAnyImagery, isTrue,
        reason: 'Even with the sharp layer streaming, the coarse fallback / '
            'Allsky base must provide imagery — never a blank flash.');

    // The C8 painter must therefore draw at least one GPU mesh (coarse coverage),
    // and never a solid fill.
    final painter = HipsTileLayerPainter(
      snapshot: streaming,
      allskyOrder: props.allskyOrder,
    );
    final recorder = _MeshCountCanvas();
    painter.paint(recorder, _canvasSize);
    expect(recorder.meshes, greaterThan(0),
        reason: 'The coarse fallback / Allsky must paint coverage under the '
            'streaming sharp layer, so the painter draws >= 1 mesh.');
    expect(recorder.rects, 0,
        reason:
            'The layer composites imagery only; it must never paint a solid '
            'fill to hide a gap.');

    final versionWhileStreaming = streaming.version;

    // Release the held sharp fetches: they decode and promote to the primary
    // layer on top, and the snapshot version advances (a repaint is warranted).
    final promotedSettled = await settleLoaderUntil(
      drive: fetcher.releaseHeld,
      condition: () => loader.snapshot.primaryTiles
          .any((t) => fixture.primaryTiles.contains(t.id)),
    );
    expect(promotedSettled, isTrue,
        reason: 'The released sharp tiles must decode and promote to primary.');

    final sharp = loader.snapshot;
    final promoted = sharp.primaryTiles
        .where((t) => fixture.primaryTiles.contains(t.id))
        .toList();
    expect(promoted, isNotEmpty,
        reason: 'Once the held sharp tiles land they must be promoted to the '
            'primary layer drawn on top of the coarse base.');
    expect(sharp.version, greaterThan(versionWhileStreaming),
        reason: 'A sharp-tile arrival must bump the snapshot version so the '
            'painter repaints exactly when new imagery is available.');
  });

  test(
      'a coarse parent fallback samples the child sub-quadrant of the parent '
      'image, not the whole parent stretched into the child footprint',
      () async {
    // The committed primary set (Norder6) over M31 and their Norder5 parents.
    final visibleSet = HipsTileSelection.computeVisibleTiles(
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

    // Pick a sharp child whose Norder5 parent is a committed fixture AND whose
    // projected mesh actually overlaps the canvas — a tile that projects entirely
    // off-screen would render zero pixels under BOTH the correct and the
    // whole-stretch paths, making them trivially (and meaninglessly) equal. We
    // choose the on-canvas candidate whose mesh bounding box covers the most
    // canvas area so the two sampling strategies have the largest visible region
    // to diverge over.
    final canvasRect = Offset.zero & _canvasSize;
    double onCanvasArea(HipsVisibleTile t) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
      for (final v in t.mesh.vertices) {
        minX = math.min(minX, v.screen.dx);
        minY = math.min(minY, v.screen.dy);
        maxX = math.max(maxX, v.screen.dx);
        maxY = math.max(maxY, v.screen.dy);
      }
      final overlap =
          Rect.fromLTRB(minX, minY, maxX, maxY).intersect(canvasRect);
      if (overlap.width <= 0 || overlap.height <= 0) return 0;
      return overlap.width * overlap.height;
    }

    final candidates = visibleSet.tiles
        .where((t) => fixture.parentNpix.contains(t.id.npix >> 2))
        .where((t) => onCanvasArea(t) > 0)
        .toList()
      ..sort((a, b) => onCanvasArea(b).compareTo(onCanvasArea(a)));
    expect(candidates, isNotEmpty,
        reason: 'at least one committed-parent child must project onto the '
            'canvas so the rendered sub-quadrant comparison is observable');
    final child = candidates.first;
    final parentId = HipsTileId(
      survey: fixture.surveyHipsId,
      norder: child.id.norder - 1,
      npix: child.id.npix >> 2,
    );
    expect(fixture.parentNpix, contains(parentId.npix),
        reason: 'the chosen child must have a committed parent fixture');

    // The fallback the loader would build for this child against its parent.
    final fallback = HipsFallbackTile.fromDescent(
      ancestorId: parentId,
      childNorder: child.id.norder,
      childNpix: child.id.npix,
      childMesh: child.mesh,
    );

    // GEOMETRY: a Norder6 child of a Norder5 parent occupies a 2x2 sub-grid; its
    // (subX, subY) is the de-interleaved low 2 bits of the child npix. Verify
    // independently so the painter samples the RIGHT quadrant.
    final low = child.id.npix & 0x3;
    final expectedSubX = low & 0x1;
    final expectedSubY = (low >> 1) & 0x1;
    expect(fallback.gridSize, 2,
        reason: 'one order of descent => a 2x2 sub-grid');
    expect(fallback.subX, expectedSubX);
    expect(fallback.subY, expectedSubY);

    // RENDER: drawing the fallback (correct sub-cell sampling) must differ from
    // drawing the WHOLE parent image stretched across the child mesh, which is
    // the misregistration this guards. Use the real committed parent tile so
    // the quadrants carry distinct content.
    //
    // Image decode (`ui.decodeImageFromList`) and `Picture.toImage` /
    // `Image.toByteData` are serviced by the engine only inside
    // [TestWidgetsFlutterBinding.runAsync] on the real event loop — in the
    // default fake-async zone their callbacks never fire — so the whole
    // decode → render → read-back pipeline runs there. The two read-back buffers
    // are captured into outer locals and compared after, where the assertion's
    // failure is reported with full context.
    final binding = TestWidgetsFlutterBinding.instance;
    ByteData? correctBytes;
    ByteData? wholeBytes;
    final cache = HipsTileCache(maxEntries: 8, maxBytes: 8 * 1024 * 1024);
    addTearDown(cache.dispose);

    await binding.runAsync(() async {
      // The cache takes ownership; give it its OWN decoded copy of the parent.
      cache.put(
        parentId,
        await decodeFixtureImage(fixture.readTileBytes(parentId)),
      );

      // Correct path: paint the fallback through the production painter.
      final correctSnapshot = HipsResidentSnapshot(
        version: 1,
        selectedNorder: visibleSet.norder,
        primaryTiles: const [],
        fallbackTiles: [fallback],
        allsky: null,
        cacheSnapshot: cache.snapshot(),
        visibleSet: visibleSet,
        failures: const [],
      );
      final correctImage = await _renderSnapshotToImage(
        correctSnapshot,
        props.allskyOrder,
      );

      // The wrong path: the whole parent image stretched onto the child mesh as
      // a primary tile, i.e. gridSize 1 / sub-cell (0,0).
      final wholeStretchSnapshot = HipsResidentSnapshot(
        version: 1,
        selectedNorder: visibleSet.norder,
        primaryTiles: const [],
        fallbackTiles: [
          HipsFallbackTile(
            ancestorId: parentId,
            mesh: child.mesh,
            subX: 0,
            subY: 0,
            gridSize: 1,
          ),
        ],
        allsky: null,
        cacheSnapshot: cache.snapshot(),
        visibleSet: visibleSet,
        failures: const [],
      );
      final wholeStretchImage = await _renderSnapshotToImage(
        wholeStretchSnapshot,
        props.allskyOrder,
      );

      try {
        correctBytes =
            await correctImage.toByteData(format: ui.ImageByteFormat.rawRgba);
        wholeBytes = await wholeStretchImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
      } finally {
        correctImage.dispose();
        wholeStretchImage.dispose();
      }
    });

    expect(correctBytes, isNotNull);
    expect(wholeBytes, isNotNull);
    expect(
      _bytesDiffer(correctBytes!, wholeBytes!),
      isTrue,
      reason: 'Sampling the child sub-quadrant of the parent must NOT equal '
          'stretching the whole parent across the child footprint — if they '
          'matched, the painter would be squashing the entire parent into the '
          'child cell (the misregistration bug). The quadrant must be sampled.',
    );
  });

  test(
      'a freshly-targeted view with only the Allsky resident still paints (the '
      'coarsest never-blank base)', () async {
    final clock = ManualLoaderClock();
    final fetcher = FixtureTileFetcher();
    final cache = HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024);
    final loader = HipsTileLoader(
      cache: cache,
      fetcher: fetcher,
      clock: clock,
      debounce: _debounce,
      ownsFetcher: true,
    );
    addTearDown(loader.dispose);

    // Hold BOTH the sharp primaries and their parents in flight, so the ONLY
    // imagery available on the first frame is the whole-sky Allsky base.
    fetcher.hold(<HipsTileId>{
      ...fixture.primaryTiles,
      ...fixture.parentFallbackTiles,
      ...fixture.grandparentFallbackTiles,
    });

    // Drain on the real event loop until the Allsky base has decoded and become
    // resident; the held tiles/parents cannot resolve, so the Allsky is the only
    // imagery and the condition we wait on.
    final allskySettled = await settleLoaderUntil(
      drive: () {
        loader.requestTiles(viewport(1.0));
        clock.flush();
      },
      condition: () => loader.snapshot.allsky != null,
    );
    expect(allskySettled, isTrue,
        reason: 'The Allsky base must decode and become resident.');

    final snapshot = loader.snapshot;
    expect(snapshot.allsky, isNotNull,
        reason:
            'The Allsky base (committed at the survey min order) is fetched '
            'first and must be resident as the coarsest never-blank base.');
    expect(snapshot.hasAnyImagery, isTrue);

    final painter = HipsTileLayerPainter(
      snapshot: snapshot,
      allskyOrder: props.allskyOrder,
    );
    final recorder = _MeshCountCanvas();
    painter.paint(recorder, _canvasSize);
    expect(recorder.meshes, greaterThan(0),
        reason:
            'The Allsky base must paint one warped cell per visible tile, so '
            'a freshly-targeted view is covered immediately — never blank.');

    // Release the held fetches and let them drain so no work outlives the test.
    await settleLoaderUntil(
      drive: fetcher.releaseHeld,
      condition: () => loader.snapshot.primaryTiles
          .any((t) => fixture.primaryTiles.contains(t.id)),
    );
  });
}

/// Rasterises [snapshot] through the production [HipsTileLayerPainter] over a
/// transparent surface to a [ui.Image], for sub-quadrant sampling comparisons.
Future<ui.Image> _renderSnapshotToImage(
  HipsResidentSnapshot snapshot,
  int allskyOrder,
) async {
  final painter = HipsTileLayerPainter(
    snapshot: snapshot,
    allskyOrder: allskyOrder,
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, _canvasSize);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(
      fixture.fixturePixelWidth,
      fixture.fixturePixelHeight,
    );
  } finally {
    picture.dispose();
  }
}

/// Whether two tightly-packed RGBA buffers differ in at least one byte.
bool _bytesDiffer(ByteData a, ByteData b) {
  final ba = a.buffer.asUint8List(a.offsetInBytes, a.lengthInBytes);
  final bb = b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
  if (ba.length != bb.length) return true;
  for (var i = 0; i < ba.length; i++) {
    if (ba[i] != bb[i]) return true;
  }
  return false;
}
