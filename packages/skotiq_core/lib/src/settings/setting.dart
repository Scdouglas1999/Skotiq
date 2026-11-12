/// One declared application setting: its name, where and how it is stored,
/// its default, its bounds, who owns it when a client is linked to a host, and
/// which part of the native executor's configuration it feeds.
///
/// Everything else about a setting is derived from its declaration in
/// `app_settings_table.dart`: the field on `AppSettingsState`, the stored row,
/// the host/client wire value, export and import, the install seed, and the
/// push to the running executor.
library;

import 'dart:convert';

/// Who holds a setting when this app is linked to a host.
enum SettingSync {
  /// The host's typed settings carry it. A linked client reads and writes the
  /// host's value.
  host,

  /// The host's key/value store carries it. A linked client reads and writes
  /// the host's row.
  hostStore,

  /// It belongs to the computer whose database holds it. A linked client
  /// cannot change it, and a write from one is refused.
  thisComputer,
}

/// The parts of the native executor's configuration that settings feed. A
/// setting tagged with one of these is pushed when a run starts and again
/// whenever it changes during a run.
enum ExecutorConfig {
  location,
  parkPolicy,
  deviceRetries,
  qualityPolicy,
  safetyFailMode,
  qualityCheck,
  rejectFolder,
  observerProfile,
  adaptiveExposure,
  filterOffsets,
}

/// Returned by [Setting.fromJson] for a wire value of the wrong shape.
const Object invalidWireValue = _InvalidWireValue();

class _InvalidWireValue {
  const _InvalidWireValue();
}

/// Why a linked client changes a setting only with admin access to the host.
enum AdminOnly {
  /// Its value is a credential, such as a webhook URL or an API key. A link
  /// without admin access also reads only whether it is set.
  credential,

  /// It says where the host sends a credential it keeps in its keyring: a
  /// server, an account, a broker. Pointing it elsewhere hands that
  /// credential over. Its own value is not secret.
  credentialTarget,

  /// It names a program or script the host runs, or chooses which of them
  /// run.
  hostProgram,

  /// It is part of what stays with admin links: the host's backups, where it
  /// downloads from, and how it is reached.
  administration,
}

sealed class Setting<T> {
  const Setting(
    this.field,
    this.key,
    this.fallback, {
    this.sync = SettingSync.host,
    this.wireKey,
    this.clientKeepsOwn = false,
    this.feeds,
    this.seed,
    this.seeded = false,
    this.adminOnly,
  });

  /// Name of the field on `AppSettingsState`.
  final String field;

  /// Key of the `app_settings` row.
  final String key;

  /// Value when nothing is stored.
  final T fallback;

  final SettingSync sync;

  /// Name in the host/client wire JSON when it differs from [field].
  final String? wireKey;

  /// A display preference: a linked client stores its own value in its own
  /// database instead of writing the host's.
  final bool clientKeepsOwn;

  final ExecutorConfig? feeds;

  /// Row text written at install when it differs from the encoded [fallback].
  final String? seed;

  /// A fresh install starts with a row holding [fallback]. Without one the
  /// setting simply reads as [fallback] until it is changed.
  final bool seeded;

  /// Set when a linked client changes it only with admin access to the host,
  /// and why. The host refuses the change from any lesser link.
  final AdminOnly? adminOnly;

  bool get hasInstallRow => seeded || seed != null;

  String get wire => wireKey ?? field;

  /// Rows this setting is stored under, primary first.
  List<String> get keys => [key];

  /// The value held in [rows]. [orElse] is used when no row exists or the
  /// row cannot be read.
  T fromRows(Map<String, String> rows, T orElse) => decode(rows[key], orElse);

  /// The rows that store [value].
  Map<String, String> toRows(T value) => {key: encode(value)};

  T decode(String? raw, T orElse);

  String encode(T value);

  Object? toJson(T value) => value;

  /// The value a wire JSON value stands for, or [invalidWireValue].
  Object? fromJson(Object? json);

  /// Dart source of the field's type, for the generated state class.
  String get dartType;

  /// Dart source of [fallback], for the generated state class.
  String get fallbackSource;

  bool get isNullable => dartType.endsWith('?');

  bool valuesEqual(T a, T b) => a == b;

  /// [value] held to this setting's bounds and allowed values.
  T clean(T value) => value;

  /// This setting paired with [value], for a write of several settings.
  SettingValue<T> to(T value) => SettingValue<T>(this, clean(value));
}

/// A setting and a value for it.
final class SettingValue<T> {
  const SettingValue(this.setting, this.value);

  final Setting<T> setting;
  final T value;

  Map<String, String> get rows => setting.toRows(value);
}

final class BoolSetting extends Setting<bool> {
  const BoolSetting(
    super.field,
    super.key,
    super.fallback, {
    super.sync,
    super.wireKey,
    super.clientKeepsOwn,
    super.feeds,
    super.seed,
    super.seeded,
    super.adminOnly,
  });

  @override
  bool decode(String? raw, bool orElse) =>
      raw == null ? orElse : raw.toLowerCase() == 'true';

  @override
  String encode(bool value) => value.toString();

  @override
  Object? fromJson(Object? json) => json is bool ? json : invalidWireValue;

  @override
  String get dartType => 'bool';

  @override
  String get fallbackSource => '$fallback';
}

/// A bool with a "no stored preference" state, stored as the text `null`.
final class OptionalBoolSetting extends Setting<bool?> {
  const OptionalBoolSetting(
    String field,
    String key, {
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
  }) : super(field, key, null);

  @override
  bool? decode(String? raw, bool? orElse) {
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    return raw.toLowerCase() == 'true';
  }

  @override
  String encode(bool? value) => value == null ? 'null' : value.toString();

  @override
  Object? fromJson(Object? json) =>
      json == null || json is bool ? json : invalidWireValue;

  @override
  String get dartType => 'bool?';

  @override
  String get fallbackSource => 'null';
}

final class IntSetting extends Setting<int> {
  const IntSetting(
    super.field,
    super.key,
    super.fallback, {
    this.min,
    this.max,
    this.inputMin,
    this.inputMax,
    super.sync,
    super.wireKey,
    super.feeds,
    super.seed,
    super.seeded,
    super.adminOnly,
  });

  /// Bounds a stored or received value is held to.
  final int? min;
  final int? max;

  /// Bounds a newly entered value is held to, when they differ from [min]
  /// and [max]. A value already stored outside them is left as it is.
  final int? inputMin;
  final int? inputMax;

  int _bound(int value) {
    final lo = min, hi = max;
    if (lo != null && value < lo) return lo;
    if (hi != null && value > hi) return hi;
    return value;
  }

  @override
  int clean(int value) {
    final lo = inputMin ?? min, hi = inputMax ?? max;
    if (lo != null && value < lo) return lo;
    if (hi != null && value > hi) return hi;
    return value;
  }

  @override
  int decode(String? raw, int orElse) =>
      _bound(raw == null ? orElse : int.tryParse(raw) ?? orElse);

  @override
  String encode(int value) => value.toString();

  @override
  Object? fromJson(Object? json) =>
      json is num ? _bound(json.toInt()) : invalidWireValue;

  @override
  String get dartType => 'int';

  @override
  String get fallbackSource => '$fallback';
}

final class DoubleSetting extends Setting<double> {
  const DoubleSetting(
    super.field,
    super.key,
    super.fallback, {
    this.min,
    this.max,
    this.inputMin,
    this.inputMax,
    super.sync,
    super.wireKey,
    super.feeds,
    super.seed,
    super.seeded,
  });

  /// Bounds a stored or received value is held to.
  final double? min;
  final double? max;

  /// Bounds a newly entered value is held to, when they differ from [min]
  /// and [max]. A value already stored outside them is left as it is.
  final double? inputMin;
  final double? inputMax;

  double _bound(double value) {
    final lo = min, hi = max;
    if (lo != null && value < lo) return lo;
    if (hi != null && value > hi) return hi;
    return value;
  }

  @override
  double clean(double value) {
    final lo = inputMin ?? min, hi = inputMax ?? max;
    if (lo != null && value < lo) return lo;
    if (hi != null && value > hi) return hi;
    return value;
  }

  @override
  double decode(String? raw, double orElse) =>
      _bound(raw == null ? orElse : double.tryParse(raw) ?? orElse);

  @override
  String encode(double value) => value.toString();

  @override
  Object? fromJson(Object? json) =>
      json is num ? _bound(json.toDouble()) : invalidWireValue;

  @override
  String get dartType => 'double';

  @override
  String get fallbackSource => '$fallback';
}

/// An int the user can clear. A cleared value is stored as the text `null`,
/// which is different from no row at all (that reads as [fallback]).
final class OptionalIntSetting extends Setting<int?> {
  const OptionalIntSetting(
    super.field,
    super.key,
    super.fallback, {
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
  });

  @override
  int? decode(String? raw, int? orElse) {
    if (raw == null) return orElse;
    if (raw == 'null' || raw.isEmpty) return null;
    return int.tryParse(raw) ?? orElse;
  }

  @override
  String encode(int? value) => value == null ? 'null' : value.toString();

  @override
  Object? fromJson(Object? json) {
    if (json == null) return null;
    return json is num ? json.toInt() : invalidWireValue;
  }

  @override
  String get dartType => 'int?';

  @override
  String get fallbackSource => '$fallback';
}

/// A double the user can clear. See [OptionalIntSetting].
final class OptionalDoubleSetting extends Setting<double?> {
  const OptionalDoubleSetting(
    super.field,
    super.key,
    super.fallback, {
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
  });

  @override
  double? decode(String? raw, double? orElse) {
    if (raw == null) return orElse;
    if (raw == 'null' || raw.isEmpty) return null;
    return double.tryParse(raw) ?? orElse;
  }

  @override
  String encode(double? value) => value == null ? 'null' : value.toString();

  @override
  Object? fromJson(Object? json) {
    if (json == null) return null;
    return json is num ? json.toDouble() : invalidWireValue;
  }

  @override
  String get dartType => 'double?';

  @override
  String get fallbackSource => '$fallback';
}

final class TextSetting extends Setting<String> {
  const TextSetting(
    super.field,
    super.key,
    super.fallback, {
    this.allowed,
    this.normalize,
    this.emptyWireIsFallback = false,
    this.mirrorKey,
    super.sync,
    super.wireKey,
    super.clientKeepsOwn,
    super.feeds,
    super.seed,
    super.seeded,
    super.adminOnly,
  });

  /// When set, any other stored or received text reads as [fallback].
  final List<String>? allowed;

  /// Applied to every stored or received value.
  final String Function(String value)? normalize;

  /// An empty wire value means "not set" and reads as [fallback].
  final bool emptyWireIsFallback;

  /// An older row holding the same value. It is read when the primary row is
  /// blank and written alongside it on this computer.
  final String? mirrorKey;

  String _clean(String value) {
    final permitted = allowed;
    if (permitted != null && !permitted.contains(value)) return fallback;
    final fix = normalize;
    return fix == null ? value : fix(value);
  }

  @override
  List<String> get keys => [key, if (mirrorKey != null) mirrorKey!];

  @override
  String fromRows(Map<String, String> rows, String orElse) {
    final mirror = mirrorKey;
    if (mirror == null) return decode(rows[key], orElse);
    final own = rows[key];
    if (own != null && own.trim().isNotEmpty) return decode(own, orElse);
    if (rows.containsKey(key) && !rows.containsKey(mirror)) {
      return decode(own, orElse);
    }
    return decode(rows[mirror], orElse);
  }

  @override
  Map<String, String> toRows(String value) => {
    key: value,
    if (mirrorKey != null) mirrorKey!: value,
  };

  @override
  String clean(String value) => _clean(value);

  @override
  String decode(String? raw, String orElse) => _clean(raw ?? orElse);

  @override
  String encode(String value) => value;

  @override
  Object? fromJson(Object? json) {
    if (json is! String) return invalidWireValue;
    if (emptyWireIsFallback && json.isEmpty) return fallback;
    return _clean(json);
  }

  @override
  String get dartType => 'String';

  @override
  String get fallbackSource => dartStringLiteral(fallback);
}

/// Text with a "not set" state.
final class OptionalTextSetting extends Setting<String?> {
  const OptionalTextSetting(
    String field,
    String key, {
    this.unsetText = 'null',
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
    super.adminOnly,
  }) : super(field, key, null);

  /// Row text that stands for "not set": `null` or the empty string.
  final String unsetText;

  @override
  String? decode(String? raw, String? orElse) {
    if (raw == null || raw.isEmpty) return null;
    if (unsetText == 'null' && raw == 'null') return null;
    return raw;
  }

  @override
  String encode(String? value) => value ?? unsetText;

  @override
  Object? fromJson(Object? json) =>
      json == null || json is String ? json : invalidWireValue;

  @override
  String get dartType => 'String?';

  @override
  String get fallbackSource => 'null';
}

/// An enum stored and sent by name. An unknown name reads as [fallback].
final class EnumSetting<E extends Enum> extends Setting<E> {
  const EnumSetting(
    super.field,
    super.key,
    super.fallback,
    this.values, {
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
  });

  final List<E> values;

  E _byName(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  @override
  E decode(String? raw, E orElse) => _byName(raw);

  @override
  String encode(E value) => value.name;

  @override
  Object? toJson(E value) => value.name;

  @override
  Object? fromJson(Object? json) =>
      json is String ? _byName(json) : invalidWireValue;

  @override
  String get dartType => '$E';

  @override
  String get fallbackSource => '$E.${fallback.name}';
}

/// A per-filter on/off map stored as a JSON object. Unreadable text reads as
/// an empty map.
final class BoolMapSetting extends Setting<Map<String, bool>> {
  const BoolMapSetting(
    String field,
    String key, {
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
  }) : super(field, key, const {});

  @override
  Map<String, bool> decode(String? raw, Map<String, bool> orElse) {
    if (raw == null || raw.isEmpty || raw == 'null') return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v == true));
      }
    } catch (_) {
      // Not JSON: no per-filter choices.
    }
    return const {};
  }

  @override
  String encode(Map<String, bool> value) => jsonEncode(value);

  @override
  Object? fromJson(Object? json) {
    if (json is! Map) return invalidWireValue;
    final out = <String, bool>{};
    for (final entry in json.entries) {
      out[entry.key.toString()] = entry.value == true;
    }
    return out;
  }

  @override
  String get dartType => 'Map<String, bool>';

  @override
  String get fallbackSource => 'const {}';

  @override
  bool valuesEqual(Map<String, bool> a, Map<String, bool> b) =>
      _mapsEqual(a, b);
}

/// A per-filter number map stored as a JSON object. Unreadable text reads as
/// an empty map.
final class DoubleMapSetting extends Setting<Map<String, double>> {
  /// With [fixedKeys], the map always has exactly the entries of [entries]:
  /// one missing from the stored object reads as its value there, and others
  /// are dropped.
  const DoubleMapSetting(
    String field,
    String key, {
    Map<String, double> entries = const {},
    this.fixedKeys = false,
    super.sync,
    super.wireKey,
    super.feeds,
    super.seeded,
  }) : super(field, key, entries);

  final bool fixedKeys;

  @override
  Map<String, double> decode(String? raw, Map<String, double> orElse) {
    if (fixedKeys) {
      if (raw == null || raw.trim().isEmpty) return fallback;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) return fallback;
        return {
          for (final entry in fallback.entries)
            entry.key: switch (decoded[entry.key]) {
              final num n => n.toDouble(),
              _ => entry.value,
            },
        };
      } catch (_) {
        return fallback;
      }
    }
    if (raw == null || raw.isEmpty || raw == 'null') return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
        );
      }
    } catch (_) {
      // Not a JSON object of numbers: no per-filter values.
    }
    return const {};
  }

  @override
  String encode(Map<String, double> value) => jsonEncode(value);

  @override
  Object? fromJson(Object? json) {
    if (json is! Map) return invalidWireValue;
    final out = <String, double>{};
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is num) out[entry.key.toString()] = value.toDouble();
    }
    return out;
  }

  @override
  String get dartType => 'Map<String, double>';

  @override
  String get fallbackSource {
    if (fallback.isEmpty) return 'const {}';
    final entries = fallback.entries
        .map((e) => '${dartStringLiteral(e.key)}: ${e.value}')
        .join(', ');
    return 'const {$entries}';
  }

  @override
  bool valuesEqual(Map<String, double> a, Map<String, double> b) =>
      _mapsEqual(a, b);
}

bool _mapsEqual<V>(Map<String, V> a, Map<String, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// [value] as a single-quoted Dart string literal.
String dartStringLiteral(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}

/// Rows whose keys start with [prefix] and always live on the same machine:
/// one row per host or per id, or a feature's group of rows.
final class SettingFamily {
  const SettingFamily(this.prefix, {required this.sync, this.adminOnly});

  final String prefix;

  final SettingSync sync;

  /// As [Setting.adminOnly], for every row of the family.
  final AdminOnly? adminOnly;

  bool holds(String key) => key.startsWith(prefix);
}
