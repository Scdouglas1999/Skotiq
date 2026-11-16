import '../celestial_object.dart';

/// Reads the nebula light table (`nebula_light.csv`, written by
/// `tools/catalog_prep/nebula_light/build_nebula_light.py`): the light of
/// each OpenNGC nebula a published emission or reflection catalog matched,
/// keyed by its OpenNGC name ("NGC7023"). Lines starting with `#` and the
/// column header are skipped.
///
/// Throws [FormatException] on a row that does not name a known light, so a
/// damaged table is noticed instead of quietly classing nebulae by OpenNGC
/// type alone.
Map<String, NebulaLight> parseNebulaLightTable(String text) {
  final table = <String, NebulaLight>{};
  for (final line in text.split('\n')) {
    final row = line.trim();
    if (row.isEmpty || row.startsWith('#') || row.startsWith('Name;')) {
      continue;
    }
    final fields = row.split(';');
    final light = fields.length > 1
        ? NebulaLight.values.asNameMap()[fields[1]]
        : null;
    if (light == null) {
      throw FormatException('Not a nebula light row', row);
    }
    table[fields[0]] = light;
  }
  return table;
}
