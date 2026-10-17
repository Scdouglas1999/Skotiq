import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_planetarium/nightshade_planetarium.dart'
    as planetarium_v1;

/// Renders the planetarium sky using the v1 `nightshade_planetarium` engine.
///
/// This is the single go-forward renderer. Subclasses ([FullScreenSkyView])
/// inherit this stable surface; the widget simply forwards to
/// [planetarium_v1.InteractiveSkyView].
class AdaptiveInteractiveSkyView extends ConsumerWidget {
  const AdaptiveInteractiveSkyView({
    super.key,
    this.onObjectSelected,
    this.onCoordinateTapped,
    this.onObjectTapped,
    this.showFOV = false,
    this.customFOV,
    this.fovCenter,
    this.observedObjectIds = const {},
    this.listedObjectIds = const {},
    this.sequencedObjectIds = const {},
    this.bortleClass = 5,
    this.horizonAltitudes,
    this.measurementMode = false,
    this.backgroundLayer,
    this.syncViewPoseFromV1 = false,
  });

  final ValueChanged<planetarium_v1.CelestialObject?>? onObjectSelected;
  final ValueChanged<planetarium_v1.CelestialCoordinate>? onCoordinateTapped;
  final void Function(
    planetarium_v1.CelestialObject? object,
    planetarium_v1.CelestialCoordinate coordinates,
    Offset screenPosition,
  )? onObjectTapped;

  final bool showFOV;
  final (double width, double height)? customFOV;
  final planetarium_v1.CelestialCoordinate? fovCenter;
  final Set<String> observedObjectIds;
  final Set<String> listedObjectIds;

  /// Catalog IDs/names that are targets of the currently loaded sequence.
  final Set<String> sequencedObjectIds;
  final int bortleClass;
  final List<double>? horizonAltitudes;

  /// When true, click-drag measures angular separation + position angle instead
  /// of panning. Forwarded to the v1 [planetarium_v1.InteractiveSkyView].
  final bool measurementMode;

  /// An optional layer composited beneath the star field — the sky-survey
  /// imagery mosaic. Null (the default) is the plain star chart.
  ///
  /// Lives on the shared adapter rather than on one subclass so that subclass
  /// does not have to override [build] and re-forward every parameter — a field
  /// added here but missed there would be silently dropped.
  final planetarium_v1.SkyBackgroundLayer? backgroundLayer;

  /// Ignored: the v1 widget owns its own pose. Accepted only so existing
  /// callers keep compiling.
  final bool syncViewPoseFromV1;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return planetarium_v1.InteractiveSkyView(
      onObjectSelected: onObjectSelected,
      onCoordinateTapped: onCoordinateTapped,
      onObjectTapped: onObjectTapped,
      showFOV: showFOV,
      showCrosshair: ref.watch(imagingViewerStateProvider).showCrosshair,
      customFOV: customFOV,
      fovCenter: fovCenter,
      observedObjectIds: observedObjectIds,
      listedObjectIds: listedObjectIds,
      sequencedObjectIds: sequencedObjectIds,
      bortleClass: bortleClass,
      horizonAltitudes: horizonAltitudes,
      measurementMode: measurementMode,
      backgroundLayer: backgroundLayer,
    );
  }
}
