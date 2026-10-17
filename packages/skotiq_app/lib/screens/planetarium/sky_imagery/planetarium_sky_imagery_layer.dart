// The planetarium's sky-survey imagery layer: real DSS imagery streamed behind
// the star chart at the narrow fields where the catalogue runs out.
//
// ## The problem it solves
//
// The chart is drawn from the HYG catalogue — ~118,000 stars, about 2.9 per
// square degree. At a 1.5-degree field centred on M42 that is fifteen stars on
// an otherwise empty screen. A 1.5-degree field is an ordinary imaging field,
// so the planetarium was at its least useful exactly where an imager needs it
// most: deciding how to frame a target. Real imagery fixes that, and the app
// already had the machinery — a complete HiPS stack built for the framing
// screen. This layer is the wiring, not a second implementation.
//
// ## What it does, and does not, own
//
// It owns: when to run, where each tile lands on the planetarium's canvas, and
// staying quiet when the network is not there.
//
// It does not own: fetching, decoding, caching, debouncing, cancellation or the
// never-blank level-of-detail strategy. All of that is skotiq_core's shared
// `HipsTileLoader` (reached through the C7 [hipsResidentTilesProvider]) — the
// same instance the framing screen drives, so there is one tile cache in the
// process, not two.
//
// ## Registration
//
// Tiles have to land where the stars say they should; imagery that disagrees
// with the chart is worse than no imagery. The loader's own meshes are built
// through the *framing* screen's projection, which the planetarium does not
// use, so they are discarded and rebuilt through [SkyFovProjector] — the public
// mirror of `SkyCanvasPainter`'s geometry, pinned against the painter's real
// output by test. See `planetarium_sky_geometry.dart`.
//
// ## Offline is the normal case
//
// An observatory laptop on an isolated LAN cannot reach CDS. Every failure path
// here ends in "show the star chart": a failed `properties` fetch leaves the
// layer transparent, failed tiles leave it transparent, and after a batch that
// produces failures and no imagery at all the layer stops asking for a while
// rather than re-issuing dozens of doomed requests on every pan. No banner, no
// dialog, no exception.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The resident-snapshot type lives in skotiq_core's src services layer and
// is intentionally not surfaced through the public barrel, matching the framing
// tile layer's import convention.
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../framing/painters/hips_tile_layer_painter.dart';
import '../../framing/widgets/hips_attribution_badge.dart';
import 'planetarium_sky_geometry.dart';
import 'planetarium_sky_imagery_providers.dart';

/// How long the layer stops requesting tiles after a batch that produced
/// failures and no imagery at all.
///
/// This is the offline case: on an isolated LAN every request fails after a DNS
/// or connect timeout, and without a pause each pan would issue another few
/// dozen of them and log another few dozen warnings. Backing off costs a user
/// with a flaky connection at most one minute of imagery; it saves an offline
/// user from a permanent retry storm. Requests resume on the first view change
/// after the window expires.
const Duration kPlanetariumSkyImageryOfflineBackoff = Duration(seconds: 60);

/// Backdrop painted under the tile mosaic while imagery is on screen.
///
/// The sky view's own opaque background is suppressed while this layer is
/// showing (that is the point — otherwise it would bury the imagery), so this
/// layer is responsible for covering the canvas. Matching the sky painter's
/// astronomical-night zenith colour keeps the transition invisible and means a
/// region the mosaic has not covered yet reads as empty sky rather than as a
/// hole punched through the app.
const Color kPlanetariumSkyImageryBackdrop = Color(0xFF0A0A1A);

/// Streams HiPS survey imagery behind the planetarium star chart.
///
/// Mount it through [InteractiveSkyView]'s [SkyBackgroundLayer] slot, not as a
/// free-standing overlay: the slot is what puts it *under* the stars and what
/// stops the sky painter drawing its opaque gradient on top of it.
///
/// Renders nothing (and touches no network) when the layer is inactive — user
/// toggle off, field too wide, or the survey has no verified pyramid.
class PlanetariumSkyImageryLayer extends ConsumerStatefulWidget {
  const PlanetariumSkyImageryLayer({super.key});

  @override
  ConsumerState<PlanetariumSkyImageryLayer> createState() =>
      _PlanetariumSkyImageryLayerState();
}

class _PlanetariumSkyImageryLayerState
    extends ConsumerState<PlanetariumSkyImageryLayer> {
  /// Monotonic version stamped onto the reprojected snapshot handed to the
  /// painter. Bumped whenever the reprojection inputs change, because that
  /// integer is the painter's entire `shouldRepaint` decision — the meshes move
  /// with the view pose, not just with the loader.
  int _reprojectedVersion = 0;

  /// Memo key for the last reprojection: `(loader snapshot version, view pose,
  /// canvas size, sidereal time)`. Recomputing 25 vertices per tile is cheap,
  /// but doing it on rebuilds that changed none of those would churn the
  /// painter's version and force pointless repaints.
  Object? _reprojectionKey;
  HipsResidentSnapshot? _reprojected;

  /// When set, viewport requests are suspended until this time — see
  /// [kPlanetariumSkyImageryOfflineBackoff].
  DateTime? _backoffUntil;

  /// The tile encoding to request: JPEG when the survey publishes it (small,
  /// and this is a background layer, not photometry), else whatever the survey
  /// declares first. Never fabricated.
  HipsTileFormat _formatFor(HipsProperties props) =>
      props.hasJpeg ? HipsTileFormat.jpeg : props.preferredFormat;

  /// Applies the offline circuit breaker to [snapshot].
  ///
  /// Trips only when a generation produces failures AND leaves nothing on
  /// screen. Partial failures with imagery present are normal (a survey does
  /// not publish every tile at every order) and must not stop the layer.
  void _updateBackoff(HipsResidentSnapshot snapshot) {
    if (snapshot.hasAnyImagery) {
      _backoffUntil = null;
      return;
    }
    if (snapshot.failures.isEmpty) return;
    _backoffUntil = DateTime.now().add(kPlanetariumSkyImageryOfflineBackoff);
  }

  bool get _backedOff {
    final until = _backoffUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Pushes the current planetarium view into the shared loader.
  ///
  /// The loader debounces, deduplicates and cancels internally, so this may be
  /// called on every frame; a pose that has not changed is a no-op inside it.
  void _pushViewport({
    required PlanetariumSkyProjection projection,
    required HipsProperties props,
  }) {
    if (_backedOff) return;

    final notifier = ref.read(hipsResidentTilesProvider.notifier);
    notifier.setSurvey(kPlanetariumSkyImagerySurvey);
    notifier.requestViewport(
      // The framing plate scale is a shim that reproduces the planetarium's
      // level of detail and field radius; the geometry it implies is never
      // drawn (see PlanetariumSkyTiles.plateScaleFor).
      plateScale: PlanetariumSkyTiles.plateScaleFor(
        projection.canvasSize,
        projection.pixelsPerDegree,
      ),
      target: FramingTarget(
        name: 'planetarium-view',
        raHours: projection.center.ra,
        decDegrees: projection.center.dec,
      ),
      canvasSize: projection.canvasSize,
      zoom: 1.0,
      pan: Offset.zero,
      // The view rotation is already baked into the projector this layer draws
      // through, so the loader must not apply one as well: it would only skew
      // the disc-query radius, and its meshes are discarded regardless.
      rotationDegrees: 0.0,
      format: _formatFor(props),
      props: props,
    );
  }

  /// Reprojects the loader's snapshot for the current pose, memoized.
  HipsResidentSnapshot _reprojectFor({
    required HipsResidentSnapshot source,
    required PlanetariumSkyProjection projection,
    required HipsProperties props,
    required String surveyId,
    required Object key,
  }) {
    final cached = _reprojected;
    if (cached != null && _reprojectionKey == key) return cached;

    _reprojectionKey = key;
    _reprojectedVersion++;
    final next = PlanetariumSkyTiles.reproject(
      source: source,
      projector: projection.projector,
      props: props,
      surveyId: surveyId,
      version: _reprojectedVersion,
    );
    _reprojected = next;
    return next;
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(planetariumSkyImageryActiveProvider)) {
      return const SizedBox.shrink();
    }

    // Zoomed out past the threshold: the star chart is the better view. Request
    // nothing and draw nothing, but stay mounted — the `ref.watch` below keeps
    // the shared autoDispose loader (and its warm tile cache) alive so zooming
    // back in does not re-download the pyramid.
    final withinFov = ref.watch(planetariumSkyImageryWithinFovProvider);

    // Resolved once per survey by the shared provider (the attribution badge
    // consumes the same one), so a pan never re-fetches it. Null while loading
    // and after a failure: the layer then contributes nothing and the star
    // chart is the whole view.
    final props = ref
        .watch(framingHipsPropertiesProvider(kPlanetariumSkyImagerySurvey))
        .valueOrNull;
    if (props == null) return const SizedBox.shrink();

    // A survey tiled in galactic or ecliptic coordinates would be addressed
    // with equatorial pixel indices here and land in visibly the wrong place.
    // Refuse rather than misregister.
    if (props.frame != HipsFrame.equatorial) return const SizedBox.shrink();

    final snapshot = ref.watch(hipsResidentTilesProvider);
    final viewState = ref.watch(skyViewStateProvider);
    final location = ref.watch(observerLocationProvider);
    // Minute-precision time, matching what the sky painter renders with — the
    // sidereal time used to place imagery in the alt-az frame must be the same
    // one used to place the stars, or the two would drift apart within a
    // minute.
    final observationMinute = ref.watch(observationMinuteProvider);
    // The alt-az frame is defined against a site. Without one the projection
    // below resolves to null and the layer paints nothing, which is the same
    // answer the star chart gives.
    final site = location.site;
    final lstHours =
        viewState.viewMode == SkyViewMode.horizontal && site != null
            ? AstronomyCalculations.localSiderealTime(
                observationMinute,
                site.longitude,
              )
            : null;

    _updateBackoff(snapshot);

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasSize = constraints.biggest;
          final projection = PlanetariumSkyProjection.resolve(
            viewState: viewState,
            canvasSize: canvasSize,
            latitude: site?.latitude,
            lstHours: lstHours,
          );
          if (projection == null) return const SizedBox.expand();

          // Drive the loader after the frame, so the request reflects the
          // geometry just laid out and no provider is mutated during build.
          if (withinFov) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _pushViewport(projection: projection, props: props);
            });
          }

          if (!withinFov || !snapshot.hasAnyImagery) {
            // Nothing resident yet (or ever, offline). Stay transparent: the
            // sky view is still painting its own background because
            // `planetariumSkyImageryVisibleProvider` is false too, so the user
            // sees the ordinary star chart.
            return const SizedBox.expand();
          }

          final surveyId = HipsSurveyAddress.forSurvey(
            kPlanetariumSkyImagerySurvey,
          ).surveyId;
          final painterSnapshot = _reprojectFor(
            source: snapshot,
            projection: projection,
            props: props,
            surveyId: surveyId,
            key: Object.hash(
              snapshot.version,
              viewState,
              canvasSize,
              lstHours,
            ),
          );
          if (!painterSnapshot.hasAnyImagery) return const SizedBox.expand();

          return ColoredBox(
            color: kPlanetariumSkyImageryBackdrop,
            child: CustomPaint(
              size: Size.infinite,
              painter: HipsTileLayerPainter(
                snapshot: painterSnapshot,
                // Must match the order the loader actually fetched the Allsky
                // at, or the packed grid is sliced at the wrong cell size.
                allskyOrder: props.allskyOrder,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The survey credit shown while planetarium imagery is on screen.
///
/// CDS and the survey publishers require the `obs_copyright` credit whenever
/// their imagery is displayed, so this is a licence obligation, not chrome. It
/// is a separate widget from [PlanetariumSkyImageryLayer] because the imagery
/// itself is composited *underneath* the star field, where a text pill would be
/// drawn over by the chart and would not be tappable; the credit belongs in the
/// screen's chrome above everything.
class PlanetariumSkyImageryAttribution extends ConsumerWidget {
  const PlanetariumSkyImageryAttribution({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(planetariumSkyImageryVisibleProvider);
    if (!visible) return const SizedBox.shrink();

    final props = ref
        .watch(framingHipsPropertiesProvider(kPlanetariumSkyImagerySurvey))
        .valueOrNull;
    // Static registry credit as the floor: a failed / not-yet-resolved
    // `properties` fetch must not leave publisher imagery on screen with no
    // acknowledgement at all.
    final entry = HipsSurveyRegistry.entryFor(kPlanetariumSkyImagerySurvey);
    return HipsAttributionBadge(
      properties: props,
      visible: true,
      fallbackCredit: entry.attributionCredit,
      fallbackCreditUrl: entry.attributionUrl,
    );
  }
}
