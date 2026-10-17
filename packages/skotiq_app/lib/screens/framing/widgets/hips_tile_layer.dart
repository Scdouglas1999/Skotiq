// The Flutter-side GPU HiPS framing tile layer.
//
// This is the [ConsumerWidget] the framing screen inserts into the framing
// render path's `Stack` as the bottom-most *imagery* layer (above the starfield
// fallback, under the grid and the FOV/mosaic overlays). It does three jobs and
// nothing else:
//
//   1. **Drive the loader.** On every layout pass and every framing-state change
//      (target, survey, zoom, pan, rotation) it measures the real canvas with a
//      [LayoutBuilder], resolves the SAME [FramingPlateScale] the survey
//      background and overlays use (via the shared canvas resolution rule), and
//      pushes that exact viewport into the [HipsTileLoader] through the
//      [hipsResidentTilesProvider] notifier. The loader debounces / dedups /
//      cancels internally, so this widget may push on every frame without
//      thrashing the network.
//   2. **Resolve survey metadata.** A HiPS view needs the survey `properties`
//      (order range + tile width + preferred format) to drive LOD selection.
//      This widget watches the single shared [framingHipsPropertiesProvider]
//      (fetched once per survey, also consumed by the attribution
//      badge), so a survey switch fetches the document once, pan/zoom
//      never re-fetch it, and there is exactly one fetch / cache / error surface
//      per survey.
//   3. **Paint the resident snapshot.** It watches [hipsResidentTilesProvider]
//      and hands the versioned [HipsResidentSnapshot] to [HipsTileLayerPainter],
//      which composites the resident tiles as GPU textured meshes. When the
//      layer is inactive (feature off, or the survey has no verified HiPS
//      pyramid) or has no imagery yet, it paints nothing and stays fully
//      transparent so the framing canvas's existing single survey snapshot /
//      starfield shows through as the outermost never-blank fallback.
//
// ## Platform independence (hard requirement)
//
// Nothing here touches the planetarium renderer. The HiPS tiles are a
// Flutter-side, GPU-composited layer inside the framing render path, so HiPS
// framing works independently of the planetarium screen.
//
// ## No FramingCanvas prop changes
//
// This widget is fully self-contained: it measures its own canvas, resolves its
// own plate scale with the shared rule, and reads framing state from the
// provider. The framing screen drops it into the `Stack` at the background
// z-index without adding a single parameter to [FramingCanvas]. It is wrapped in
// an [IgnorePointer] so pan/rotate gestures fall through to the canvas beneath.
//
// ## Failure surfacing
//
// A `properties` fetch failure is surfaced (logged via the loader's error sink
// path and exposed through [HipsLayerPropertiesState]); the layer then stays
// transparent and the single survey snapshot remains visible — never a silent
// blank. Per-tile fetch failures are surfaced by the loader into the snapshot's
// `failures` list (an attribution/diagnostic concern handled by the screen).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// FramingPlateScale + the shared canvas plate-scale resolution rule live in
// skotiq_core's models layer and are intentionally not surfaced through the
// public barrel (they are app->core src-model types shared with the framing
// painters), so they are imported directly here, matching the convention used by
// the framing painters and the framing canvas itself.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_hips_projection.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';

import '../painters/hips_tile_layer_painter.dart';

/// The Flutter-side GPU HiPS framing tile layer widget.
///
/// Drop it into the framing `Stack` at the background imagery z-index. It is a
/// [ConsumerStatefulWidget] (rather than a plain [ConsumerWidget]) only so it can
/// schedule the post-frame viewport push (which needs `mounted` across the frame
/// boundary). Survey `properties` are resolved by the single shared
/// [framingHipsPropertiesProvider] (fetched once per survey), which both this
/// layer and the attribution badge consume — so there is exactly one fetch /
/// one cache / one error surface per survey.
class HipsTileLayer extends ConsumerStatefulWidget {
  const HipsTileLayer({super.key});

  @override
  ConsumerState<HipsTileLayer> createState() => _HipsTileLayerState();
}

class _HipsTileLayerState extends ConsumerState<HipsTileLayer> {
  /// The framing preview tile encoding for [props]: JPEG when the survey
  /// publishes it (the framing preview encoding), else the survey's first
  /// declared format. Never fabricated.
  HipsTileFormat _formatFor(HipsProperties props) =>
      props.hasJpeg ? HipsTileFormat.jpeg : props.preferredFormat;

  /// Pushes the current framing viewport into the loader after the frame is laid
  /// out, so the tile request always reflects the geometry just painted.
  ///
  /// Scheduled as a post-frame callback because it reads the resolved plate
  /// scale and canvas size computed during build and must run after layout
  /// without mutating provider state mid-build.
  void _pushViewport({
    required HipsSurveyAddress address,
    required FramingState framingState,
    required FramingPlateScale plateScale,
    required Size canvasSize,
    required HipsProperties properties,
    required HipsTileFormat format,
  }) {
    final target = framingState.target;
    if (target == null) return; // Nothing framed: no sky centre to request.
    if (canvasSize.isEmpty) return; // Not laid out yet.

    final notifier = ref.read(hipsResidentTilesProvider.notifier);
    notifier.setSurvey(framingState.surveySource);
    notifier.requestViewport(
      plateScale: plateScale,
      target: target,
      canvasSize: canvasSize,
      zoom: framingState.zoom,
      pan: Offset(framingState.panX, framingState.panY),
      rotationDegrees: framingState.rotation,
      format: format,
      props: properties,
    );
  }

  /// Resolves the plate scale exactly as the framing canvas does, so the tiles
  /// register to the survey background and overlays to the pixel. Uses the
  /// shared [FramingPlateScaleResolution.resolveForCanvas] rule — the single
  /// source of truth both the canvas and this layer call.
  FramingPlateScale _resolvePlateScale(
    Size canvasSize,
    FramingState framingState,
  ) {
    final target = framingState.target;
    final view = FramingProjectionView(
      plateScale: framingState.plateScale,
      previewFovDegrees: framingState.previewFovDegrees,
      centerRaHours: target?.raHours ?? 0,
      centerDecDegrees: target?.decDegrees ?? 0,
      zoom: framingState.zoom,
      panX: framingState.panX,
      panY: framingState.panY,
      rotationDegrees: framingState.rotation,
    );
    return FramingPlateScaleResolution.resolveForCanvas(canvasSize, view);
  }

  @override
  Widget build(BuildContext context) {
    final framingState = ref.watch(framingProvider);
    final active = ref.watch(
      hipsFramingActiveProvider(framingState.surveySource),
    );

    // When inactive (feature off, or survey lacks a verified HiPS pyramid) the
    // layer is fully transparent and contributes nothing: the framing canvas's
    // single survey snapshot / starfield is the visible background. We still
    // return a zero-cost transparent box so the Stack slot is stable.
    if (!active) {
      return const SizedBox.expand();
    }

    final snapshot = ref.watch(hipsResidentTilesProvider);
    final address = HipsSurveyAddress.forSurvey(framingState.surveySource);

    // The survey `properties` are resolved once per survey by the shared
    // provider (also consumed by the attribution badge). While it is loading or
    // after a failure its value is null/errored, and the layer stays transparent
    // so the framing canvas's single survey snapshot shows through (never-blank,
    // error surfaced by the provider). Pan/zoom/rotate do not change the family
    // key, so they never re-fetch it.
    final propertiesAsync =
        ref.watch(framingHipsPropertiesProvider(framingState.surveySource));
    final properties = propertiesAsync.valueOrNull;

    return IgnorePointer(
      // Gestures (pan/rotate) belong to the framing canvas beneath this layer;
      // the HiPS tiles are pure imagery and must never intercept input.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasSize = constraints.biggest;
          final plateScale = _resolvePlateScale(canvasSize, framingState);

          // Drive the loader once properties are ready for THIS survey. Pushed
          // after the frame so it reflects the just-resolved geometry and never
          // mutates provider state during build.
          if (properties != null && !canvasSize.isEmpty) {
            final format = _formatFor(properties);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _pushViewport(
                address: address,
                framingState: framingState,
                plateScale: plateScale,
                canvasSize: canvasSize,
                properties: properties,
                format: format,
              );
            });
          }

          // Nothing to paint until imagery is resident; stay transparent so the
          // single survey snapshot underneath remains visible (never-blank).
          if (!snapshot.hasAnyImagery || properties == null) {
            return const SizedBox.expand();
          }

          return CustomPaint(
            size: Size.infinite,
            painter: HipsTileLayerPainter(
              snapshot: snapshot,
              // The Allsky is fetched/keyed at the survey's published Allsky
              // order (HipsProperties.allskyOrder), NOT hips_order_min, so the
              // painter slices the packed Allsky grid at the same order the
              // loader fetched it at — they must agree or the base mis-samples.
              allskyOrder: properties.allskyOrder,
            ),
          );
        },
      ),
    );
  }
}
