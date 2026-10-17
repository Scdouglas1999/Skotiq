import 'dart:convert';

import '../../models/hardware_presets/hardware_preset_models.dart';

/// Merges the built-in hardware catalogs (telescopes + camera defaults) with
/// user-saved overrides, and exposes search + camera auto-match for the
/// Onboarding & First-Light preset library.
///
/// This deliberately mirrors the discipline of
/// `services/smart_night/hardware_specs_service.dart`:
///   * override-merge semantics (overrides win over built-ins, de-duped by id),
///   * normalize + alias camera name matching, and
///   * `*FromJson` decoders that throw [FormatException] on a non-list payload
///     rather than silently substituting an empty catalog.
///
/// The service performs **no I/O** — encoding/decoding helpers are pure and the
/// persistence read/write lives in the provider layer. A malformed persisted
/// override surfaces as a [FormatException] instead of being swallowed.
class HardwarePresetsService {
  /// `app_settings` key under which the JSON-encoded user telescope overrides
  /// are persisted.
  static const String telescopeOverridesSettingKey =
      'hardware_presets.telescopes.v1';

  /// `app_settings` key under which the JSON-encoded user camera overrides are
  /// persisted.
  static const String cameraOverridesSettingKey = 'hardware_presets.cameras.v1';

  final List<TelescopePreset> _telescopeOverrides;
  final List<CameraDefaultsPreset> _cameraOverrides;
  final List<TelescopePreset> _telescopeCatalog;
  final List<CameraDefaultsPreset> _cameraCatalog;

  const HardwarePresetsService({
    List<TelescopePreset> telescopeOverrides = const [],
    List<CameraDefaultsPreset> cameraOverrides = const [],
    List<TelescopePreset> telescopeCatalog = builtInTelescopePresets,
    List<CameraDefaultsPreset> cameraCatalog = builtInCameraDefaultsPresets,
  }) : _telescopeOverrides = telescopeOverrides,
       _cameraOverrides = cameraOverrides,
       _telescopeCatalog = telescopeCatalog,
       _cameraCatalog = cameraCatalog;

  /// Returns a copy of this service with the supplied overrides swapped in,
  /// preserving the (immutable) built-in catalogs.
  HardwarePresetsService withOverrides({
    List<TelescopePreset>? telescopeOverrides,
    List<CameraDefaultsPreset>? cameraOverrides,
  }) {
    return HardwarePresetsService(
      telescopeOverrides: telescopeOverrides ?? _telescopeOverrides,
      cameraOverrides: cameraOverrides ?? _cameraOverrides,
      telescopeCatalog: _telescopeCatalog,
      cameraCatalog: _cameraCatalog,
    );
  }

  /// All telescope presets: overrides first, then built-ins, de-duped by [id]
  /// with the override winning. A user override sharing an id with a built-in
  /// therefore replaces it, while a built-in id never appears twice.
  List<TelescopePreset> allTelescopes() =>
      _merge(_telescopeOverrides, _telescopeCatalog, (preset) => preset.id);

  /// All camera-defaults presets: overrides first, then built-ins, de-duped by
  /// [id] with the override winning.
  List<CameraDefaultsPreset> allCameras() =>
      _merge(_cameraOverrides, _cameraCatalog, (preset) => preset.id);

  /// Case-insensitive substring search over a telescope's display name, brand,
  /// and model. Results are ranked exact > startsWith > contains, ties broken by
  /// display name. An empty/whitespace query returns every preset in
  /// [allTelescopes] order.
  List<TelescopePreset> searchTelescopes(String query) {
    return _search(
      allTelescopes(),
      query,
      (preset) => [preset.displayName, preset.brand, preset.model],
    );
  }

  /// Case-insensitive substring search over a camera's display name, brand,
  /// model, and [CameraDefaultsPreset.aliases]. Ranked exact > startsWith >
  /// contains. An empty/whitespace query returns every preset in [allCameras]
  /// order.
  List<CameraDefaultsPreset> searchCameras(String query) {
    return _search(
      allCameras(),
      query,
      (preset) => [
        preset.displayName,
        preset.brand,
        preset.model,
        ...preset.aliases,
        for (final alias in preset.aliases) '${preset.brand} $alias',
      ],
    );
  }

  /// Resolves a connected camera's reported [cameraName] to a preset so it can
  /// auto-suggest acquisition defaults. Matching mirrors
  /// `HardwareSpecsService.matchCamera`: names are normalized (lower-cased,
  /// non-alphanumerics stripped) and compared first for an exact alias/name hit,
  /// then for a containment hit. Overrides take priority over built-ins.
  ///
  /// Returns `null` for an empty/unknown name rather than guessing — a wrong
  /// auto-fill is worse than none.
  CameraDefaultsPreset? matchCameraByName(
    String? cameraName, {
    bool exactOnly = false,
  }) {
    if (cameraName == null) return null;
    final normalizedQuery = _normalize(cameraName);
    if (normalizedQuery.isEmpty) return null;

    final cameras = allCameras();

    // Pass 1: exact match against any normalized name/alias.
    for (final preset in cameras) {
      for (final name in _candidateNames(preset)) {
        if (_normalize(name) == normalizedQuery) return preset;
      }
    }

    if (exactOnly) return null;

    // Pass 2: containment in either direction, guarded by a minimum length so
    // short tokens (e.g. a two-character alias) cannot produce spurious hits.
    // The longest catalog name that participates wins, so "ZWO ASI2600MM"
    // prefers the most specific preset.
    CameraDefaultsPreset? bestPreset;
    var bestNameLength = 0;
    for (final preset in cameras) {
      for (final name in _candidateNames(preset)) {
        final normalizedName = _normalize(name);
        if (normalizedName.length < 4) continue;
        final contains =
            normalizedQuery.contains(normalizedName) ||
            normalizedName.contains(normalizedQuery);
        if (contains && normalizedName.length > bestNameLength) {
          bestPreset = preset;
          bestNameLength = normalizedName.length;
        }
      }
    }
    return bestPreset;
  }

  // Persistence (de)serialization. Pure — no I/O. Used by the provider.

  /// Decodes a list of [TelescopePreset] from an already-JSON-decoded [Object]
  /// (the form returned by `jsonDecode`). `null` yields an empty list; a
  /// non-list payload throws [FormatException], matching
  /// `HardwareSpecsService.cameraOverridesFromJson`.
  static List<TelescopePreset> telescopeOverridesFromJson(Object? decoded) {
    if (decoded == null) return const [];
    if (decoded is! List) {
      throw const FormatException('Telescope preset overrides must be a list');
    }
    return decoded
        .map(
          (value) =>
              TelescopePreset.fromJson((value as Map).cast<String, dynamic>()),
        )
        .toList();
  }

  /// Decodes a list of [CameraDefaultsPreset] from an already-JSON-decoded
  /// [Object]. `null` yields an empty list; a non-list payload throws
  /// [FormatException].
  static List<CameraDefaultsPreset> cameraOverridesFromJson(Object? decoded) {
    if (decoded == null) return const [];
    if (decoded is! List) {
      throw const FormatException('Camera preset overrides must be a list');
    }
    return decoded
        .map(
          (value) => CameraDefaultsPreset.fromJson(
            (value as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }

  /// Encodes telescope overrides to a JSON string for persistence.
  static String encodeTelescopeOverrides(List<TelescopePreset> overrides) =>
      jsonEncode(overrides.map((preset) => preset.toJson()).toList());

  /// Encodes camera overrides to a JSON string for persistence.
  static String encodeCameraOverrides(List<CameraDefaultsPreset> overrides) =>
      jsonEncode(overrides.map((preset) => preset.toJson()).toList());

  // Internals.

  /// Merges [overrides] (first) with [catalog], de-duping by the key returned
  /// from [idOf] so an override replaces the matching built-in and each id
  /// appears at most once. Override ordering is preserved; built-ins follow in
  /// their catalog order.
  static List<T> _merge<T>(
    List<T> overrides,
    List<T> catalog,
    String Function(T) idOf,
  ) {
    final result = <T>[];
    final seen = <String>{};
    for (final item in overrides) {
      if (seen.add(idOf(item))) result.add(item);
    }
    for (final item in catalog) {
      if (seen.add(idOf(item))) result.add(item);
    }
    return result;
  }

  /// Ranks [items] against [query] over the fields produced by [fieldsOf].
  /// Rank order: exact field match (0) > field starts-with (1) > field contains
  /// (2). Within a rank, the original [items] order is preserved (stable sort).
  static List<T> _search<T>(
    List<T> items,
    String query,
    List<String> Function(T) fieldsOf,
  ) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return items;

    final ranked = <_RankedHit<T>>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      var bestRank = _noMatchRank;
      for (final field in fieldsOf(item)) {
        final normalizedField = field.trim().toLowerCase();
        if (normalizedField.isEmpty) continue;
        final int rank;
        if (normalizedField == normalizedQuery) {
          rank = 0;
        } else if (normalizedField.startsWith(normalizedQuery)) {
          rank = 1;
        } else if (normalizedField.contains(normalizedQuery)) {
          rank = 2;
        } else {
          continue;
        }
        if (rank < bestRank) bestRank = rank;
      }
      if (bestRank != _noMatchRank) {
        ranked.add(_RankedHit(item: item, rank: bestRank, order: i));
      }
    }

    ranked.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) return byRank;
      return a.order.compareTo(b.order);
    });

    return ranked.map((hit) => hit.item).toList();
  }

  static const int _noMatchRank = 1 << 30;

  static List<String> _candidateNames(CameraDefaultsPreset preset) => [
    preset.displayName,
    preset.model,
    ...preset.aliases,
    for (final alias in preset.aliases) '${preset.brand} $alias',
  ];

  /// Lower-cases and strips every non-alphanumeric character so that
  /// "ASI2600MM Pro", "ASI2600MM-Pro" and "asi2600mmpro" all collapse to the
  /// same token. Identical normalization to `HardwareSpecsService._normalize`.
  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

class _RankedHit<T> {
  final T item;
  final int rank;
  final int order;

  const _RankedHit({
    required this.item,
    required this.rank,
    required this.order,
  });
}
