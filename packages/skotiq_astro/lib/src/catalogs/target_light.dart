import '../celestial_object.dart';

/// What light a target gives, read from its catalog object type. Nothing
/// here names an object: the class comes from the type the catalog gives.
///
/// The deep-sky catalog types a nebula emission or reflection from published
/// emission and reflection catalogs (the nebula light table, see
/// `dsoTypeFromOpenNgcCode`): a nebula OpenNGC files only as "Neb" or
/// "Cl+N" reads "Reflection Nebula" or "Cluster + Emission Nebula" when one
/// of those catalogs classifies it.
enum TargetLight {
  /// Line emission, imaged through narrowband filters: emission nebulae, HII
  /// regions, supernova remnants, planetary nebulae, a cluster in an
  /// emission nebula, and a nebula no catalog classifies further (OpenNGC
  /// "Neb" or "Cl+N" with no match in the nebula light table).
  emission,

  /// Starlight, imaged through LRGB: galaxies, reflection and dark nebulae,
  /// a cluster in a reflection nebula, clusters, stars, and a target whose
  /// type is not known.
  broadband,
}

/// The light [objectType] gives. Reads the app's type names ("Supernova
/// Remnant", "Cluster + Nebula"), OpenNGC codes ("SNR", "Cl+N") and SIMBAD
/// codes ("HII", "PN", "RNe"), and any free text that names them ("Emission/
/// Reflection Nebula"). A type naming emission is emission even when it
/// names reflection too; a reflection or dark nebula is broadband; any other
/// nebula is emission.
TargetLight targetLight(String? objectType) {
  final type = (objectType ?? '').toLowerCase();
  final words = type
      .split(RegExp('[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
  final emission =
      type.contains('emission') ||
      type.contains('supernova') ||
      type.contains('planetary') ||
      type.contains('h ii') ||
      words.contains('hii') ||
      words.contains('snr') ||
      words.contains('pn') ||
      words.contains('emn');
  final reflection =
      type.contains('reflection') ||
      words.contains('rfn') ||
      words.contains('rne');
  final dark =
      type.contains('dark') || words.contains('drkn') || words.contains('dne');
  final nebula =
      type.contains('nebul') || type.contains('cl+n') || words.contains('neb');

  if (emission) return TargetLight.emission;
  if (reflection || dark) return TargetLight.broadband;
  if (nebula) return TargetLight.emission;
  return TargetLight.broadband;
}

extension DsoTypeLight on DsoType {
  /// The light this type gives; the same answer [targetLight] gives for its
  /// [DsoTypeExtension.displayName].
  TargetLight get light => switch (this) {
    DsoType.clusterWithNebulosity ||
    DsoType.clusterWithEmissionNebula ||
    DsoType.planetaryNebula ||
    DsoType.hiiRegion ||
    DsoType.emissionNebula ||
    DsoType.nebula ||
    DsoType.supernova => TargetLight.emission,
    DsoType.star ||
    DsoType.doubleStar ||
    DsoType.association ||
    DsoType.openCluster ||
    DsoType.globularCluster ||
    DsoType.clusterWithReflectionNebula ||
    DsoType.galaxy ||
    DsoType.galaxyPair ||
    DsoType.galaxyTriplet ||
    DsoType.galaxyGroup ||
    DsoType.darkNebula ||
    DsoType.reflectionNebula ||
    DsoType.nova ||
    DsoType.starCloud ||
    DsoType.asterism ||
    DsoType.other => TargetLight.broadband,
  };
}
