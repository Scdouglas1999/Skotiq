import 'target_designation.dart';

/// One name-search hit from the installed catalogs.
class CatalogSearchResult {
  final String name;
  final String catalogId;
  final double ra; // Degrees
  final double dec; // Degrees
  final String type;
  final double? magnitude;
  final String? constellation;
  final String? size;

  const CatalogSearchResult({
    required this.name,
    required this.catalogId,
    required this.ra,
    required this.dec,
    required this.type,
    this.magnitude,
    this.constellation,
    this.size,
  });
}

/// A name reduced to what a search compares: "Messier 42", "M 42" and "m042"
/// are one designation; so are "Caldwell 49" and "C 049", "SH 2-129" and
/// "Sh2-129". Anything else is lower-cased with separators removed.
String normalizeCatalogSearchText(String value) {
  final designation = CatalogDesignation.parse(value);
  if (designation != null) return designation.key;
  final compact = value.toLowerCase().replaceAll(_separators, '');
  return compact.replaceFirstMapped(
    _paddedNumber,
    (match) => '${match.group(1)}${int.parse(match.group(2)!)}',
  );
}

final _separators = RegExp(r'[^a-z0-9]+');
final _paddedNumber = RegExp(r'^(m|ngc|ic|hip|hd|hyg)0*(\d+)$');

/// The searchable names of every object in a catalog, parallel to its object
/// list: per object, its names lower-cased and its names normalized, each
/// joined with a newline.
///
/// Built once where the catalog is parsed (a background isolate). Searching
/// used to normalize every name of every object again for each query, about
/// 400 ms per keystroke with the star catalog installed.
class CatalogNameKeys {
  final List<String> lower;
  final List<String> normalized;

  const CatalogNameKeys(this.lower, this.normalized);

  static const empty = CatalogNameKeys([], []);

  /// Append one object's [names]. A caller that already knows the normalized
  /// form of a name (a bare catalog id) passes it in [alreadyNormalized] and
  /// leaves it out of [names] to skip the parse; [lowerOnly] names are
  /// matched as typed only.
  static void add(
    List<String> lower,
    List<String> normalized,
    Iterable<String> names, {
    Iterable<String> lowerOnly = const [],
    Iterable<String> alreadyNormalized = const [],
  }) {
    final l = StringBuffer();
    final n = StringBuffer();
    void put(StringBuffer buffer, String value) {
      if (value.isEmpty) return;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(value);
    }

    for (final name in names) {
      put(l, name.toLowerCase());
      put(n, normalizeCatalogSearchText(name));
    }
    for (final name in lowerOnly) {
      put(l, name.toLowerCase());
    }
    for (final key in alreadyNormalized) {
      put(n, key);
    }
    lower.add(l.toString());
    normalized.add(n.toString());
  }
}

/// A search string prepared once and matched against [CatalogNameKeys].
class CatalogNameQuery {
  final String _raw;
  final String _normalized;

  CatalogNameQuery(String query)
    : _raw = query.toLowerCase(),
      _normalized = normalizeCatalogSearchText(query);

  /// Whether object [i] has a name that contains the query, or (normalized)
  /// contains it or is contained in it. The last direction is what lets
  /// "NGC 7000 nebula" still find NGC 7000.
  bool matches(CatalogNameKeys keys, int i) {
    if (keys.lower[i].contains(_raw)) return true;
    if (_normalized.isEmpty) return false;
    final normalized = keys.normalized[i];
    return normalized.contains(_normalized) ||
        _hasSegmentWithin(normalized, _normalized);
  }

  /// Whether one of object [i]'s names is the query, as typed or normalized.
  bool equals(CatalogNameKeys keys, int i) =>
      _hasSegment(keys.lower[i], _raw) ||
      (_normalized.isNotEmpty && _hasSegment(keys.normalized[i], _normalized));

  static bool _hasSegment(String joined, String value) {
    var start = 0;
    while (start <= joined.length) {
      var end = joined.indexOf('\n', start);
      if (end < 0) end = joined.length;
      if (end - start == value.length && joined.startsWith(value, start)) {
        return true;
      }
      start = end + 1;
    }
    return false;
  }

  /// Whether any newline-separated segment of [joined] occurs inside [text].
  static bool _hasSegmentWithin(String joined, String text) {
    var start = 0;
    while (start < joined.length) {
      var end = joined.indexOf('\n', start);
      if (end < 0) end = joined.length;
      final length = end - start;
      if (length > 0 && length <= text.length) {
        for (var at = 0; at + length <= text.length; at++) {
          var k = 0;
          while (k < length &&
              joined.codeUnitAt(start + k) == text.codeUnitAt(at + k)) {
            k++;
          }
          if (k == length) return true;
        }
      }
      start = end + 1;
    }
    return false;
  }
}
