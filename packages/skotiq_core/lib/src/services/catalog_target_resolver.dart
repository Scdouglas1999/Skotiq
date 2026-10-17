import 'dart:math' as math;

import '../database/database.dart' as db;

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
    final sep = _angularSeparationArcmin(
      ra1Hours: raHours,
      dec1Deg: decDegrees,
      ra2Hours: target.ra,
      dec2Deg: target.dec,
    );
    if (sep <= maxSepArcmin && sep < bestSep) {
      bestSep = sep;
      best = target;
    }
  }

  return best;
}

String _normalizeCatalogName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

double _angularSeparationArcmin({
  required double ra1Hours,
  required double dec1Deg,
  required double ra2Hours,
  required double dec2Deg,
}) {
  final ra1Rad = ra1Hours * 15.0 * math.pi / 180.0;
  final dec1Rad = dec1Deg * math.pi / 180.0;
  final ra2Rad = ra2Hours * 15.0 * math.pi / 180.0;
  final dec2Rad = dec2Deg * math.pi / 180.0;

  final dRa = ra1Rad - ra2Rad;
  final sinDec1 = math.sin(dec1Rad);
  final cosDec1 = math.cos(dec1Rad);
  final sinDec2 = math.sin(dec2Rad);
  final cosDec2 = math.cos(dec2Rad);

  final a = cosDec2 * math.sin(dRa);
  final b = cosDec1 * sinDec2 - sinDec1 * cosDec2 * math.cos(dRa);
  final c = sinDec1 * sinDec2 + cosDec1 * cosDec2 * math.cos(dRa);

  final sepRad = math.atan2(math.sqrt(a * a + b * b), c);
  return sepRad * 180.0 / math.pi * 60.0;
}
