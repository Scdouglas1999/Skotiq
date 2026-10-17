import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

typedef FinderChartCatalogSnapshot = ({
  List<Star> stars,
  List<DeepSkyObject> dsos,
});

/// The patch of sky a finder chart covers: an equatorial centre plus the
/// short-axis field of view, in degrees.
///
/// Charts are always described in equatorial coordinates even when the
/// planetarium is being flown in the horizontal frame, because that is the
/// frame the printed header, the catalog query and the mount all speak.
typedef FinderChartRegion = ({
  double centerRaHours,
  double centerDecDeg,
  double fovDeg,
});

/// The catalog snapshot for an explicit chart [FinderChartRegion].
///
/// Rendering can legitimately show an empty frame while catalogs load, but an
/// exported PDF is a durable artifact: it must wait for both spatial indexes
/// and preserve load failures instead of treating them as empty catalogs.
///
/// Takes the region as a parameter rather than reading the live view centre, so
/// a chart titled for an object cannot be filled from wherever the user
/// happened to have panned. The exporter decides which region it is charting
/// and asks for exactly that.
final finderChartCatalogSnapshotProvider = FutureProvider.autoDispose
    .family<FinderChartCatalogSnapshot, FinderChartRegion>((ref, region) async {
  // Fail loudly on a catalog that could not load; an export must never silently
  // become an empty chart.
  final starIndex = await _awaitIndex(
    ref.watch(starSpatialIndexProvider.future),
    'star',
  );
  final dsoIndex = await _awaitIndex(
    ref.watch(dsoSpatialIndexProvider.future),
    'deep-sky object',
  );

  final (starMagLimit, dsoMagLimit) = ref.watch(dynamicMagnitudeLimitsProvider);
  final quality = ref.watch(fovAdaptiveQualityProvider);
  // The chart bitmap is square, so the region is square too — deliberately not
  // `skyViewAspectRatioProvider`, which would gather a wide strip of sky for a
  // square page and leave the chart's corners empty.
  const aspect = 1.0;

  return (
    stars: List<Star>.unmodifiable(
      starIndex.queryBrightestInViewport(
        region.centerRaHours,
        region.centerDecDeg,
        region.fovDeg,
        maxMagnitude: starMagLimit,
        maxResults: quality.maxStarsToRender,
        aspectRatio: aspect,
      ),
    ),
    dsos: List<DeepSkyObject>.unmodifiable(
      dsoIndex.queryBrightestInViewport(
        region.centerRaHours,
        region.centerDecDeg,
        region.fovDeg,
        maxMagnitude: dsoMagLimit,
        maxResults: quality.maxDsosToRender,
        aspectRatio: aspect,
      ),
    ),
  );
});

/// Where a finder chart should be pointed, and the pose to render it with.
///
/// Both exporters go through this so the PDF's header, its footer coordinates
/// and its star field cannot disagree:
///
///  * When the chart is titled for an object ([subject] non-null) it is centred
///    on that object, not on the live view — otherwise the title names an
///    object that appears nowhere on the page.
///  * The pose is always [SkyViewMode.equatorial]. In the horizontal frame
///    `centerRA`/`centerDec` hold the preserved *inactive* equatorial pose, so
///    rendering or printing them reports a centre tens of degrees from where the
///    user is looking.
({FinderChartRegion region, SkyViewState pose}) finderChartPose({
  required SkyViewState viewState,
  required (double raHours, double decDeg) viewCenter,
  CelestialCoordinate? subject,
}) {
  final centerRa = subject?.ra ?? viewCenter.$1;
  final centerDec = subject?.dec ?? viewCenter.$2;
  return (
    region: (
      centerRaHours: centerRa,
      centerDecDeg: centerDec,
      fovDeg: viewState.fieldOfView,
    ),
    pose: viewState.copyWith(
      viewMode: SkyViewMode.equatorial,
      centerRA: centerRa,
      centerDec: centerDec,
    ),
  );
}

Future<T> _awaitIndex<T>(Future<T> index, String label) async {
  try {
    return await index;
  } catch (error, stack) {
    Error.throwWithStackTrace(
      StateError('Could not load the $label catalog: $error'),
      stack,
    );
  }
}
