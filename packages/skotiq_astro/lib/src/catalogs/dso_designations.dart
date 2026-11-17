import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'catalog_name_search.dart';
import 'target_designation.dart';

/// Deep-sky objects by every designation that names them ("NGC1976", "M42",
/// "LBN 974") and every common name the catalog gives them ("Flaming Star
/// Nebula"), compared as [normalizeCatalogSearchText] compares them. A
/// designation two objects list names the brighter one, and a designation
/// always wins over another object's common name.
class DsoDesignations {
  final Map<String, DeepSkyObject> _byKey;
  final Map<String, DeepSkyObject> _byCommonName;
  final List<DeepSkyObject> _withSize;

  const DsoDesignations._(this._byKey, this._byCommonName, this._withSize);

  static const DsoDesignations empty = DsoDesignations._({}, {}, []);

  /// [objects] brightest first, as the OpenNGC reader lists them; then
  /// [kSupplementalDsos] for any designation the catalog does not list.
  factory DsoDesignations.of(List<DeepSkyObject> objects) {
    final byKey = <String, DeepSkyObject>{};
    final byCommonName = <String, DeepSkyObject>{};
    final withSize = <DeepSkyObject>[];
    for (final object in [...objects, ...kSupplementalDsos]) {
      for (final designation in [object.id, ...object.catalogIds]) {
        byKey.putIfAbsent(
          normalizeCatalogSearchText(designation),
          () => object,
        );
      }
      for (final common in (object.commonNames ?? '').split(',')) {
        if (common.trim().isEmpty) continue;
        byCommonName.putIfAbsent(
          normalizeCatalogSearchText(common),
          () => object,
        );
      }
      if ((object.sizeArcMin ?? 0) > 0) withSize.add(object);
    }
    return DsoDesignations._(byKey, byCommonName, withSize);
  }

  /// The object [designation] (or a common name the catalog lists) names, or
  /// null when none does.
  DeepSkyObject? named(String designation) {
    if (designation.trim().isEmpty) return null;
    final key = normalizeCatalogSearchText(designation);
    return _byKey[key] ?? _byCommonName[key];
  }

  /// The object whose catalogued size holds the position [raHours],
  /// [decDegrees]: inside half its major axis of its center. Of nested
  /// objects (a cluster inside a nebula) it is the one the position sits most
  /// centrally in, by distance over that radius. Null outside every object.
  DeepSkyObject? containing({
    required double raHours,
    required double decDegrees,
  }) {
    final point = CelestialCoordinate(ra: raHours, dec: decDegrees);
    DeepSkyObject? best;
    var bestFraction = double.infinity;
    for (final object in _withSize) {
      final radiusDeg = object.sizeArcMin! / 120.0;
      // Cheap reject before the great-circle distance.
      if ((object.coordinates.dec - decDegrees).abs() > radiusDeg) continue;
      final fraction = point.separationDegrees(object.coordinates) / radiusDeg;
      if (fraction <= 1.0 && fraction < bestFraction) {
        best = object;
        bestFraction = fraction;
      }
    }
    return best;
  }

  /// The object a saved target is: the one its [catalogId] names, else the
  /// one its [name] names, else the one whose size holds its position
  /// ([containing]) when given; null for a target none of those identifies.
  DeepSkyObject? ofTarget({
    String? catalogId,
    required String name,
    double? raHours,
    double? decDegrees,
  }) =>
      (catalogId == null ? null : named(catalogId)) ??
      named(name) ??
      (raHours == null || decDegrees == null
          ? null
          : containing(raHours: raHours, decDegrees: decDegrees));
}
