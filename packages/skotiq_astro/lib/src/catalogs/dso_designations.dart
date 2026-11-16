import '../celestial_object.dart';
import 'catalog_name_search.dart';
import 'target_designation.dart';

/// Deep-sky objects by every designation that names them ("NGC1976", "M42",
/// "LBN 974"), compared as [normalizeCatalogSearchText] compares them. A
/// designation two objects list names the brighter one.
class DsoDesignations {
  final Map<String, DeepSkyObject> _byKey;

  const DsoDesignations._(this._byKey);

  static const DsoDesignations empty = DsoDesignations._({});

  /// [objects] brightest first, as the OpenNGC reader lists them; then
  /// [kSupplementalDsos] for any designation the catalog does not list.
  factory DsoDesignations.of(List<DeepSkyObject> objects) {
    final byKey = <String, DeepSkyObject>{};
    for (final object in [...objects, ...kSupplementalDsos]) {
      for (final designation in [object.id, ...object.catalogIds]) {
        byKey.putIfAbsent(
          normalizeCatalogSearchText(designation),
          () => object,
        );
      }
    }
    return DsoDesignations._(byKey);
  }

  /// The object [designation] names, or null when none does.
  DeepSkyObject? named(String designation) {
    if (designation.trim().isEmpty) return null;
    return _byKey[normalizeCatalogSearchText(designation)];
  }

  /// The object a saved target is: the one its [catalogId] names, else the
  /// one its [name] names; null for a target no designation identifies (a
  /// position the user entered).
  DeepSkyObject? ofTarget({String? catalogId, required String name}) =>
      (catalogId == null ? null : named(catalogId)) ?? named(name);
}
