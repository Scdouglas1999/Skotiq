// Riverpod providers for the F5 catalog overlay. Kept separate from the
// existing `annotation_settings_provider` because the catalog overlay is
// a transient, view-only feature — there is no settings-table persistence
// and no annotation-snapshot mutation.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/catalog_overlay_service.dart';
import '../services/wcs/gnomonic_projection.dart';

/// Whether the catalog overlay is currently displayed on the live preview.
/// Defaults to off — the overlay is opt-in, similar to the existing star /
/// grid / crosshair toggles.
final catalogOverlayEnabledProvider = StateProvider<bool>((_) => false);

/// Magnitude limit used when querying the catalog. Default is 10 to match
/// the mission spec ("default mag 10"). UI exposes a dropdown to switch
/// between 6, 8, 10, 12, 14.
final catalogOverlayMagnitudeLimitProvider = StateProvider<double>((_) => 10.0);

/// Whether to include catalog DSOs (Messier / NGC / IC). Default on.
final catalogOverlayIncludeDsosProvider = StateProvider<bool>((_) => true);

/// Whether to include HYG catalog stars. Default off — the star count
/// inside a typical FOV is large and most users come to the overlay for
/// DSOs first.
final catalogOverlayIncludeStarsProvider = StateProvider<bool>((_) => false);

/// Catalog overlay service instance. Singleton-per-Riverpod-container so
/// the underlying planetarium catalogs are loaded once and cached.
final catalogOverlayServiceProvider = Provider<CatalogOverlayService>((_) {
  return CatalogOverlayService(source: PlanetariumCatalogOverlaySource());
});

/// Query parameters that uniquely identify a catalog overlay request.
/// Used as the `family` argument so flipping any input triggers a fresh
/// future without invalidating other open frames.
class CatalogOverlayQuery {
  final SolvedWcs wcs;
  final double magnitudeLimit;
  final bool includeStars;
  final bool includeDsos;

  const CatalogOverlayQuery({
    required this.wcs,
    required this.magnitudeLimit,
    required this.includeStars,
    required this.includeDsos,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CatalogOverlayQuery &&
        wcs.raHours == other.wcs.raHours &&
        wcs.decDegrees == other.wcs.decDegrees &&
        wcs.rotationDeg == other.wcs.rotationDeg &&
        wcs.pixelScaleArcsec == other.wcs.pixelScaleArcsec &&
        wcs.imageWidth == other.wcs.imageWidth &&
        wcs.imageHeight == other.wcs.imageHeight &&
        magnitudeLimit == other.magnitudeLimit &&
        includeStars == other.includeStars &&
        includeDsos == other.includeDsos;
  }

  @override
  int get hashCode => Object.hash(
    wcs.raHours,
    wcs.decDegrees,
    wcs.rotationDeg,
    wcs.pixelScaleArcsec,
    wcs.imageWidth,
    wcs.imageHeight,
    magnitudeLimit,
    includeStars,
    includeDsos,
  );
}

/// Future provider that runs the catalog overlay query asynchronously
/// so the UI thread is never blocked on catalog IO. Use this with
/// `.watch(...)` in a Consumer to get loading / data / error states for
/// free.
final catalogOverlayQueryProvider = FutureProvider.autoDispose
    .family<CatalogOverlayResult, CatalogOverlayQuery>((ref, query) async {
      final service = ref.watch(catalogOverlayServiceProvider);
      return service.queryFov(
        wcs: query.wcs,
        magnitudeLimit: query.magnitudeLimit,
        includeStars: query.includeStars,
        includeDsos: query.includeDsos,
      );
    });

/// Currently selected catalog object (for the details side panel). Null
/// when nothing is selected.
final selectedCatalogOverlayObjectProvider =
    StateProvider<CatalogOverlayObject?>((_) => null);
