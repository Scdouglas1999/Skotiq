
import '../database/database.dart' as db;
import 'package:skotiq_astro/skotiq_astro.dart';

/// Maximum angular separation when linking a planetarium/catalog object to
/// an existing row in the targets library.
const double catalogTargetMatchMaxSepArcsec = 30.0;

/// Resolve a saved targets-library row for a catalog or planetarium object.
///
/// Matching order: exact name, catalog id, then coordinate proximity within
/// [catalogTargetMatchMaxSepArcsec]. Returns `null` when no library target
/// matches — callers should skip integration-goal lookup in that case.
db.Target? resolveDbTargetForCatalog({
  required List<db.Target> candidates,
  required String targetName,
  String? catalogId,
  required double raHours,
  required double decDegrees,
}) {
  if (candidates.isEmpty) return null;

  final normalizedName = _normalizeCatalogName(targetName);
  if (normalizedName.isNotEmpty) {
    for (final target in candidates) {
      if (_normalizeCatalogName(target.name) == normalizedName) {
        return target;
      }
    }
  }

  final catalogCandidates = <String>{
    if (catalogId != null && catalogId.trim().isNotEmpty)
      _normalizeCatalogName(catalogId),
    if (normalizedName.isNotEmpty) normalizedName,
  };
  if (catalogCandidates.isNotEmpty) {
    for (final target in candidates) {
      final id = target.catalogId;
      if (id == null) continue;
      if (catalogCandidates.contains(_normalizeCatalogName(id))) {
        return target;
      }
    }
  }

  const maxSepArcmin = catalogTargetMatchMaxSepArcsec / 60.0;
  db.Target? best;
  var bestSep = double.infinity;

  for (final target in candidates) {
    final sep =
        AstronomyCalculations.angularSeparation(
          ra1Deg: raHours * 15.0,
          dec1Deg: decDegrees,
          ra2Deg: target.ra * 15.0,
          dec2Deg: target.dec,
        ) *
        60.0;
    if (sep <= maxSepArcmin && sep < bestSep) {
      bestSep = sep;
      best = target;
    }
  }

  return best;
}

String _normalizeCatalogName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
