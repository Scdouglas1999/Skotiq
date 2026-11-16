import '../celestial_object.dart';
import 'catalog_name_search.dart';

/// Which catalog object a name designates. "M1", "NGC 1952" and "ngc1952"
/// all designate the Crab Nebula; a name no catalog object carries designates
/// nothing.
///
/// Two names are the same object only when both resolve here to one entry;
/// a near position or a similar spelling is never identity.
class CatalogIdentity<T> {
  CatalogIdentity(
    Iterable<({T object, Iterable<String> designations})> catalog,
  ) {
    for (final entry in catalog) {
      for (final designation in entry.designations) {
        final key = normalizeCatalogSearchText(designation);
        if (key.isNotEmpty) _byDesignation.putIfAbsent(key, () => entry.object);
      }
    }
  }

  /// Every object of an OpenNGC load, identified by its catalog id.
  static CatalogIdentity<String> ofDsos(Iterable<DeepSkyObject> dsos) =>
      CatalogIdentity([
        for (final dso in dsos)
          (object: dso.id, designations: [dso.id, ...dso.catalogIds]),
      ]);

  final _byDesignation = <String, T>{};

  /// The object the first of [names] that designates one designates.
  T? objectOf(Iterable<String?> names) {
    for (final name in names) {
      if (name == null || name.trim().isEmpty) continue;
      final match = _byDesignation[normalizeCatalogSearchText(name)];
      if (match != null) return match;
    }
    return null;
  }
}
