import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show
        CatalogDesignation,
        DeepSkyObject,
        TargetNameResolver,
        SelectTarget,
        ChooseTarget,
        ResolveTargetOnline,
        kWellKnownDsoNames,
        normalizeTargetName;

import '../../models/import/canonical_sequence_node.dart';
import '../sesame_name_resolver.dart';
import '../../models/import/import_result.dart';
import 'csv_parser.dart';

/// Resolves an object designation (e.g. "M31", "NGC 7000", "IC 1318") to a
/// celestial coordinate. Pluggable so the importer can be tested without a
/// real catalog, and so different deployments (desktop / mobile / headless)
/// can wire up their own catalog source (DSO file, online API, etc.).
abstract class CatalogLookup {
  /// Returns a coordinate for [designation] or `null` if the designation is
  /// not in the catalog. Implementations should be tolerant of common
  /// formatting variants ("M 31" vs "M31", "NGC7000" vs "NGC 7000").
  Future<CatalogLookupResult?> resolve(String designation);
}

class CatalogLookupResult {
  final String canonicalName;
  final double raHours;
  final double decDegrees;

  /// Catalog ids and aliases that may match the imported designation even
  /// when [canonicalName] is a friendly common name.
  final List<String> identifiers;

  const CatalogLookupResult({
    required this.canonicalName,
    required this.raHours,
    required this.decDegrees,
    this.identifiers = const [],
  });
}

/// A designation could not be resolved to one object, for a reason the user
/// should see: several objects carry the name, or the lookup service could
/// not be reached. A plain "no such object" is a null result instead.
class CatalogLookupFailure implements Exception {
  final String reason;
  const CatalogLookupFailure(this.reason);

  @override
  String toString() => 'CatalogLookupFailure: $reason';
}

/// Adapts a catalog search surface (the host's catalog over the wire) to the
/// importer's single-result lookup contract.
///
/// Only a candidate the designation names exactly is accepted: the same
/// catalog designation however it is spelled (`M42`, `M 42`, `Messier 42`),
/// or the same name. A search hit that merely contains the text is never
/// taken, so an unmatched designation stays unresolved rather than landing on
/// a different object.
class CatalogSearchLookup implements CatalogLookup {
  final Future<List<CatalogLookupResult>> Function(String designation) _search;

  const CatalogSearchLookup(this._search);

  @override
  Future<CatalogLookupResult?> resolve(String designation) async {
    final query = _IdentifierKeys.of([designation], aliases: true);
    if (query.isEmpty) return null;
    final exact = <String, CatalogLookupResult>{};
    for (final candidate in await _search(designation)) {
      if (!_hasValidCoordinates(candidate)) continue;
      final keys = _IdentifierKeys.of([
        candidate.canonicalName,
        ...candidate.identifiers,
      ], aliases: true);
      if (keys.any(query.contains)) {
        exact.putIfAbsent(_identity(candidate), () => candidate);
      }
    }
    if (exact.isEmpty) return null;
    if (exact.length > 1) {
      throw CatalogLookupFailure(
        'several catalog objects are named "$designation" '
        '(${exact.values.map((c) => c.canonicalName).join(', ')})',
      );
    }
    return exact.values.single;
  }

  /// Rows for one object can repeat across catalogs; their positions agree.
  static String _identity(CatalogLookupResult c) =>
      '${c.raHours.toStringAsFixed(3)}/${c.decDegrees.toStringAsFixed(2)}';

  static bool _hasValidCoordinates(CatalogLookupResult candidate) =>
      candidate.raHours.isFinite &&
      candidate.raHours >= 0 &&
      candidate.raHours < 24 &&
      candidate.decDegrees.isFinite &&
      candidate.decDegrees >= -90 &&
      candidate.decDegrees <= 90;
}

/// Exact-match keys of a set of identifiers: each one's catalog designation
/// key when it parses as one, and its normalized name. With [aliases], the
/// designations a well-known common name stands for are added too
/// (`Andromeda` -> `M 31`), so a wire row that carries only a common name
/// still matches the designation it stands for.
class _IdentifierKeys {
  static Set<String> of(Iterable<String> identifiers, {bool aliases = false}) {
    final keys = <String>{};
    for (final raw in identifiers) {
      if (raw.trim().isEmpty) continue;
      final designation = CatalogDesignation.parse(raw);
      if (designation != null) keys.add('d:${designation.key}');
      final name = normalizeTargetName(raw);
      if (name.isNotEmpty) keys.add('n:$name');
      if (aliases) {
        for (final id in kWellKnownDsoNames[name] ?? const <String>[]) {
          final alias = CatalogDesignation.parse(id);
          if (alias != null) keys.add('d:${alias.key}');
        }
      }
    }
    return keys;
  }
}

/// Resolves designations against the installed deep-sky catalog with
/// [TargetNameResolver], the resolver the Framing search uses: one object
/// named exactly is taken, several are reported as ambiguous, and partial
/// matches are never taken.
class ResolverCatalogLookup implements CatalogLookup {
  final Future<List<DeepSkyObject>> Function() _catalog;

  const ResolverCatalogLookup(this._catalog);

  @override
  Future<CatalogLookupResult?> resolve(String designation) async {
    final ranked = TargetNameResolver.rank(designation, await _catalog());
    switch (TargetNameResolver.decide(ranked)) {
      case SelectTarget(:final object):
        return CatalogLookupResult(
          canonicalName: object.name,
          raHours: object.coordinates.ra,
          decDegrees: object.coordinates.dec,
          identifiers: [object.id, ...object.catalogIds],
        );
      case ChooseTarget(:final candidates):
        throw CatalogLookupFailure(
          'several catalog objects are named "$designation" '
          '(${candidates.map((c) => c.object.name).join(', ')})',
        );
      case ResolveTargetOnline():
        return null;
    }
  }
}

/// Tries [primary] first and asks SIMBAD's exact name resolver only for a
/// designation [primary] knows nothing about. An ambiguous primary result is
/// reported as such, never resolved online behind the user's back.
class OnlineFallbackLookup implements CatalogLookup {
  final CatalogLookup primary;
  final SesameNameResolver online;

  const OnlineFallbackLookup({required this.primary, required this.online});

  @override
  Future<CatalogLookupResult?> resolve(String designation) async {
    final local = await primary.resolve(designation);
    if (local != null) return local;
    try {
      final resolved = await online.resolve(designation);
      if (resolved == null) return null;
      return CatalogLookupResult(
        canonicalName: resolved.mainId,
        raHours: resolved.raHours,
        decDegrees: resolved.decDegrees,
        identifiers: [resolved.mainId],
      );
    } on TargetNameLookupUnavailable catch (e) {
      throw CatalogLookupFailure(
        'not in the installed catalog, and SIMBAD could not be reached '
        '(${e.message})',
      );
    }
  }
}

/// A no-op catalog lookup. Used as the default when no catalog source has
/// been configured — every resolve returns `null` and the importer surfaces
/// the unresolved rows in `unresolved`.
class NullCatalogLookup implements CatalogLookup {
  const NullCatalogLookup();
  @override
  Future<CatalogLookupResult?> resolve(String designation) async => null;
}

/// In-memory catalog lookup useful for tests and bundled "starter" catalogs.
class InMemoryCatalogLookup implements CatalogLookup {
  final Map<String, CatalogLookupResult> _byKey;

  InMemoryCatalogLookup(Iterable<MapEntry<String, CatalogLookupResult>> entries)
    : _byKey = {for (final e in entries) _normalize(e.key): e.value};

  @override
  Future<CatalogLookupResult?> resolve(String designation) async {
    final key = _normalize(designation);
    final hit = _byKey[key];
    if (hit != null) return hit;
    // Try common aliases — strip catalog prefixes / spaces.
    for (final candidate in _candidateKeys(designation)) {
      final v = _byKey[candidate];
      if (v != null) return v;
    }
    return null;
  }

  static String _normalize(String s) =>
      s.toUpperCase().replaceAll(RegExp(r'\s+'), '');

  Iterable<String> _candidateKeys(String designation) sync* {
    final upper = designation.toUpperCase();
    yield upper.replaceAll(RegExp(r'\s+'), '');
    yield upper.replaceAll(RegExp(r'[\s\-_]'), '');
    // Strip a leading "MESSIER " / "M " prefix.
    final m = RegExp(r'^MESSIER\s*(\d+)$').firstMatch(upper);
    if (m != null) yield 'M${m.group(1)}';
  }
}

/// Outcome of an Astrobin import. The importer is async because catalog
/// resolution may hit a streaming file / remote API, but it does NOT block
/// on unresolved entries — instead it records them so the UI can show
/// "12 targets resolved, 3 needed manual coordinates".
class AstrobinImportSummary {
  /// Resolved + unresolved rows wrapped into a canonical tree.
  final CanonicalSequenceNode root;

  /// Designations the catalog couldn't resolve. UI surfaces these so the
  /// user can paste coordinates manually.
  final List<UnresolvedTarget> unresolved;

  /// Total rows scanned (including header).
  final int totalRows;

  /// Rows that were successfully turned into TargetHeaderNodes.
  final int resolvedRows;

  AstrobinImportSummary({
    required this.root,
    required this.unresolved,
    required this.totalRows,
    required this.resolvedRows,
  });
}

class UnresolvedTarget {
  final String designation;
  final int rowNum;
  final double? integrationHours;
  final String? notes;

  /// Why it was left unresolved, phrased to follow the designation.
  final String reason;

  const UnresolvedTarget({
    required this.designation,
    required this.rowNum,
    this.integrationHours,
    this.notes,
    this.reason = 'matches no catalog object by name',
  });
}

/// Importer for Astrobin per-user CSV dumps.
///
/// Astrobin offers a per-user CSV export listing every uploaded image with
/// columns like `Title`, `Subject` (object designation), `Integration` (in
/// hours), `Date`, `Filters`, `Camera`. Coordinates are usually NOT present
/// — the importer cross-references each row's designation with the
/// configured [CatalogLookup] to fill in RA/Dec.
///
/// Use case: a user wants to seed a new observing list with "everything I've
/// already shot on Astrobin" so they can track integration progress against
/// their existing portfolio.
class AstrobinImporter {
  final CatalogLookup _catalog;

  AstrobinImporter({CatalogLookup? catalog})
    : _catalog = catalog ?? const NullCatalogLookup();

  /// Quick sniff: Astrobin CSVs include `Subject` and `Integration` as
  /// canonical column headers. We accept the variant with `Object` as well
  /// since older exports use that name.
  static bool sniff(String content) {
    final firstLine = _firstNonEmptyLine(content);
    if (firstLine == null) return false;
    final lower = firstLine.toLowerCase();
    final hasSubject = lower.contains('subject') || lower.contains('object');
    final hasIntegration =
        lower.contains('integration') || lower.contains('total time');
    // Astrobin headers are typically lowercase / friendly names — and we
    // want to distinguish from Telescopius which uses "Designation".
    final isTelescopius =
        lower.contains('designation') && lower.contains('right ascension');
    return hasSubject && hasIntegration && !isTelescopius;
  }

  Future<AstrobinImportSummary> parse(
    String content, {
    String? sequenceName,
  }) async {
    final rows = CsvParser.parse(content);
    if (rows.isEmpty) {
      throw MalformedSourceError('Astrobin CSV is empty');
    }
    final header = rows.first
        .map((c) => c.trim().toLowerCase().replaceAll(RegExp(r'[\s_]'), ''))
        .toList(growable: false);
    final idxSubject = _findColumn(header, ['subject', 'object', 'target']);
    final idxIntegration = _findColumn(header, [
      'integration',
      'totaltime',
      'totalintegration',
    ]);
    if (idxSubject < 0) {
      throw MalformedSourceError(
        'Astrobin CSV missing required "Subject" column. Got: ${header.join(", ")}',
      );
    }
    final idxTitle = _findColumn(header, ['title', 'name']);
    final idxFilters = _findColumn(header, ['filters', 'filter']);
    final idxDate = _findColumn(header, ['date', 'acquisitiondate']);

    final dataRows = rows.skip(1).where((r) => _hasContent(r)).toList();
    // Group duplicate designations: the same target may appear multiple
    // times if the user uploaded several iterations. We sum integration
    // and merge notes.
    final aggregated = <String, _AggregatedTarget>{};
    final ordering = <String>[];
    var rowNum = 1;
    for (final row in dataRows) {
      rowNum++;
      String? cell(int idx) {
        if (idx < 0 || idx >= row.length) return null;
        final v = row[idx].trim();
        return v.isEmpty ? null : v;
      }

      final subject = cell(idxSubject);
      if (subject == null) continue;
      final integrationHours = _parseIntegration(cell(idxIntegration));
      final filters = cell(idxFilters);
      final title = cell(idxTitle);
      final date = cell(idxDate);

      final key = subject.toUpperCase();
      if (!aggregated.containsKey(key)) {
        ordering.add(key);
        aggregated[key] = _AggregatedTarget(subject: subject, rowNum: rowNum);
      }
      final agg = aggregated[key]!;
      if (integrationHours != null) {
        agg.integrationHours = (agg.integrationHours ?? 0) + integrationHours;
      }
      if (filters != null) agg.filters.add(filters);
      if (title != null) agg.titles.add(title);
      if (date != null) agg.dates.add(date);
    }

    // Resolve each unique designation against the catalog.
    final unresolved = <UnresolvedTarget>[];
    final children = <CanonicalSequenceNode>[];
    var resolvedRows = 0;
    for (final key in ordering) {
      final agg = aggregated[key]!;
      CatalogLookupResult? resolved;
      String? failure;
      try {
        resolved = await _catalog.resolve(agg.subject);
      } on CatalogLookupFailure catch (e) {
        failure = e.reason;
      }
      final notes = _buildNotes(agg);
      if (resolved == null) {
        unresolved.add(
          UnresolvedTarget(
            designation: agg.subject,
            rowNum: agg.rowNum,
            integrationHours: agg.integrationHours,
            notes: notes,
            reason: failure ?? 'matches no catalog object by name',
          ),
        );
        // We still emit a TargetHeaderNode with RA=0/Dec=0 so the user sees
        // the row in the preview and can paste coordinates manually. The
        // validation pipeline will surface the placeholder coords as a
        // WARNING so they're never silently used in production.
        children.add(
          CanonicalSequenceNode(
            kind: CanonicalKind.targetHeader,
            name: agg.subject,
            sourceType: 'AstrobinUnresolvedTarget',
            attributes: {
              'targetName': agg.subject,
              'raHours': 0.0,
              'decDegrees': 0.0,
              'notes': notes,
              '_unresolved': true,
              'unresolvedReason':
                  failure ?? 'matches no catalog object by name',
              if (agg.integrationHours != null)
                'astrobinIntegrationHours': agg.integrationHours,
            },
          ),
        );
        continue;
      }
      resolvedRows++;
      children.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.targetHeader,
          name: resolved.canonicalName,
          sourceType: 'AstrobinTarget',
          attributes: {
            'targetName': resolved.canonicalName,
            'raHours': resolved.raHours,
            'decDegrees': resolved.decDegrees,
            'notes': notes,
            if (agg.integrationHours != null)
              'astrobinIntegrationHours': agg.integrationHours,
          },
        ),
      );
    }

    final root = CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: sequenceName ?? 'Astrobin Import',
      sourceType: 'AstrobinCsv',
      attributes: {
        'totalRows': dataRows.length,
        'resolvedRows': resolvedRows,
        'unresolvedRows': unresolved.length,
      },
      children: children,
    );

    return AstrobinImportSummary(
      root: root,
      unresolved: unresolved,
      totalRows: dataRows.length,
      resolvedRows: resolvedRows,
    );
  }

  String? _buildNotes(_AggregatedTarget agg) {
    final parts = <String>[];
    if (agg.integrationHours != null) {
      parts.add(
        'Astrobin integration: ${agg.integrationHours!.toStringAsFixed(1)}h',
      );
    }
    if (agg.filters.isNotEmpty) {
      parts.add('Filters: ${agg.filters.join(", ")}');
    }
    if (agg.dates.isNotEmpty) {
      parts.add('Imaged: ${agg.dates.join(", ")}');
    }
    return parts.isEmpty ? null : parts.join(' | ');
  }

  /// Astrobin integration is reported as a number with optional unit. We
  /// accept `"6.5"`, `"6.5h"`, `"6h 30m"`, `"390min"`, `"6:30"`.
  static double? _parseIntegration(String? raw) {
    if (raw == null) return null;
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return null;
    // Plain number → assume hours.
    final asDouble = double.tryParse(text);
    if (asDouble != null) return asDouble;
    // "Nh", "Nh Mm".
    final hm = RegExp(
      r'^(\d+(?:\.\d+)?)\s*h(?:\s*(\d+)\s*m)?$',
    ).firstMatch(text);
    if (hm != null) {
      final h = double.tryParse(hm.group(1)!) ?? 0;
      final m = (hm.group(2) != null)
          ? (double.tryParse(hm.group(2)!) ?? 0)
          : 0;
      return h + m / 60.0;
    }
    // "Nmin" / "Nm".
    final mOnly = RegExp(r'^(\d+(?:\.\d+)?)\s*m(?:in)?$').firstMatch(text);
    if (mOnly != null) {
      final m = double.tryParse(mOnly.group(1)!) ?? 0;
      return m / 60.0;
    }
    // "H:MM".
    final colon = RegExp(r'^(\d+):(\d+)$').firstMatch(text);
    if (colon != null) {
      final h = double.tryParse(colon.group(1)!) ?? 0;
      final m = double.tryParse(colon.group(2)!) ?? 0;
      return h + m / 60.0;
    }
    return null;
  }

  static int _findColumn(List<String> header, List<String> aliases) {
    for (final alias in aliases) {
      for (var i = 0; i < header.length; i++) {
        if (header[i] == alias) return i;
      }
    }
    return -1;
  }

  static bool _hasContent(List<String> row) {
    return row.any((c) => c.trim().isNotEmpty);
  }

  static String? _firstNonEmptyLine(String content) {
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t;
    }
    return null;
  }
}

class _AggregatedTarget {
  final String subject;
  final int rowNum;
  double? integrationHours;
  final Set<String> filters = {};
  final Set<String> titles = {};
  final Set<String> dates = {};

  _AggregatedTarget({required this.subject, required this.rowNum});
}
