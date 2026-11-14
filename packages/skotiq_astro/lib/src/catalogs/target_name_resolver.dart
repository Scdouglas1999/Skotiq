import '../celestial_object.dart';
import 'target_designation.dart';

/// How well a catalog object matches a typed target name. Lower is better.
enum TargetMatchQuality {
  /// The query is one of the object's catalog designations (`M42`,
  /// `ngc 891`, `Caldwell 49`).
  designation,

  /// The query is one of the object's names (`Orion Nebula`, `Pleiades`).
  name,

  /// A designation or name of the object starts with the query.
  prefix,

  /// A designation or name of the object contains the query.
  partial;

  /// Whether this match names the object outright, so selecting it without
  /// asking is safe.
  bool get isExact => this == designation || this == name;
}

/// One catalog object matched against a query.
class RankedTarget {
  final DeepSkyObject object;
  final TargetMatchQuality quality;

  const RankedTarget(this.object, this.quality);
}

/// What pressing Enter on a target search should do.
sealed class TargetSubmitDecision {
  const TargetSubmitDecision();
}

/// Exactly one object is named by the query: select it.
class SelectTarget extends TargetSubmitDecision {
  final DeepSkyObject object;
  const SelectTarget(this.object);
}

/// Several objects carry the query as a name or designation, or only partial
/// matches exist: show the list and let the user pick.
class ChooseTarget extends TargetSubmitDecision {
  final List<RankedTarget> candidates;
  const ChooseTarget(this.candidates);
}

/// Nothing local matches; resolve the name online.
class ResolveTargetOnline extends TargetSubmitDecision {
  const ResolveTargetOnline();
}

/// Resolves typed target names against a deep-sky catalog.
///
/// Exact designations and names always rank above partial text matches, so a
/// substring that happens to appear inside some other identifier (`HTR M42`,
/// `PGC 0M42...`) can never win over the object the user named.
class TargetNameResolver {
  TargetNameResolver._();

  /// Rank every object in [catalog] (plus [kSupplementalDsos] the catalog
  /// does not already carry) against [query], best first, at most [limit].
  static List<RankedTarget> rank(
    String query,
    Iterable<DeepSkyObject> catalog, {
    int limit = 50,
  }) {
    final q = _Query.parse(query);
    if (q == null) return const [];

    final ranked = <RankedTarget>[];
    final seenKeys = <String>{};
    void consider(DeepSkyObject object) {
      final quality = _match(q, object);
      if (quality != null) ranked.add(RankedTarget(object, quality));
    }

    for (final object in catalog) {
      seenKeys.addAll(_ObjectKeys.of(object).designations);
      consider(object);
    }
    for (final object in kSupplementalDsos) {
      // Skip a supplement whose primary designation the catalog already has
      // (a future OpenNGC with the addendum merged in).
      final primary = CatalogDesignation.parse(object.catalogIds.first);
      if (primary != null && seenKeys.contains(primary.key)) continue;
      consider(object);
    }

    ranked.sort((a, b) {
      final byQuality = a.quality.index.compareTo(b.quality.index);
      if (byQuality != 0) return byQuality;
      return (a.object.magnitude ?? 99).compareTo(b.object.magnitude ?? 99);
    });
    return ranked.length > limit ? ranked.sublist(0, limit) : ranked;
  }

  /// Decide what Enter should do with an already [ranked] list.
  static TargetSubmitDecision decide(List<RankedTarget> ranked) {
    final exact = ranked.where((r) => r.quality.isExact).toList();
    final distinct = <String, RankedTarget>{
      for (final r in exact) r.object.id: r,
    };
    if (distinct.length == 1) {
      return SelectTarget(distinct.values.single.object);
    }
    if (distinct.length > 1) return ChooseTarget(distinct.values.toList());
    return const ResolveTargetOnline();
  }

  static TargetMatchQuality? _match(_Query q, DeepSkyObject object) {
    final keys = _ObjectKeys.of(object);
    final designation = q.designation;
    if (designation != null && keys.designations.contains(designation.key)) {
      return TargetMatchQuality.designation;
    }
    if (keys.names.contains(q.name) ||
        q.aliasKeys.any(keys.designations.contains)) {
      return TargetMatchQuality.name;
    }
    if (keys.texts.any((t) => t.startsWith(q.compact))) {
      return TargetMatchQuality.prefix;
    }
    if (q.compact.length >= 2 && keys.texts.any((t) => t.contains(q.compact))) {
      return TargetMatchQuality.partial;
    }
    return null;
  }
}

/// Match keys of one catalog object, computed once and cached on the object:
/// the catalog holds ~14,000 entries and every keystroke ranks all of them.
class _ObjectKeys {
  final Set<String> designations;
  final Set<String> names;
  final List<String> texts;

  _ObjectKeys(this.designations, this.names, this.texts);

  static final Expando<_ObjectKeys> _cache = Expando('targetNameKeys');

  static _ObjectKeys of(DeepSkyObject object) =>
      _cache[object] ??= _build(object);

  static _ObjectKeys _build(DeepSkyObject object) {
    final designations = <String>{
      for (final text in [object.id, object.name, ...object.catalogIds])
        if (CatalogDesignation.parse(text) case final d?) d.key,
    };
    final names = <String>{
      normalizeTargetName(object.name),
      if (object.commonNames != null)
        for (final n in object.commonNames!.split(','))
          if (n.trim().isNotEmpty) normalizeTargetName(n),
    };
    final texts = <String>{
      ...names.map((n) => n.replaceAll(' ', '')),
      ...designations,
      for (final id in [object.id, ...object.catalogIds]) _compact(id),
    }.toList(growable: false);
    return _ObjectKeys(designations, names, texts);
  }

  static String _compact(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

class _Query {
  final CatalogDesignation? designation;
  final String name;
  final String compact;
  final Set<String> aliasKeys;

  const _Query(this.designation, this.name, this.compact, this.aliasKeys);

  static _Query? parse(String raw) {
    final name = normalizeTargetName(raw);
    if (name.isEmpty) return null;
    var designation = CatalogDesignation.parse(raw);
    final alias = designation == null
        ? null
        : kDesignationAliases[designation.key];
    if (alias != null) designation = CatalogDesignation.parse(alias);
    final aliasKeys = <String>{
      for (final id in kWellKnownDsoNames[name] ?? const <String>[])
        if (CatalogDesignation.parse(id) case final d?) d.key,
    };
    return _Query(designation, name, name.replaceAll(' ', ''), aliasKeys);
  }
}
