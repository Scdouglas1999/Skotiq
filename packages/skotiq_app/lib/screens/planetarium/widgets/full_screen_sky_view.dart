import '../../../widgets/planetarium/adaptive_interactive_sky_view.dart';

/// Full-screen planetarium sky (main `/planetarium` route).
///
/// Identical to [AdaptiveInteractiveSkyView]; it exists as a named type so the
/// main chart is distinguishable from the target picker and mosaic planner at
/// its call sites. The sky-survey imagery slot is `backgroundLayer` on the
/// shared adapter, so this class does NOT override `build` — a parameter added
/// to the adapter reaches this view automatically.
class FullScreenSkyView extends AdaptiveInteractiveSkyView {
  const FullScreenSkyView({
    super.key,
    super.onObjectSelected,
    super.onCoordinateTapped,
    super.onObjectTapped,
    super.showFOV,
    super.customFOV,
    super.fovCenter,
    super.observedObjectIds,
    super.listedObjectIds,
    super.sequencedObjectIds,
    super.bortleClass,
    super.horizonAltitudes,
    super.measurementMode,
    super.backgroundLayer,
  }) : super(syncViewPoseFromV1: true);
}
