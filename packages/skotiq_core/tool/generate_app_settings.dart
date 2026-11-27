/// Writes `lib/src/settings/app_settings_state.g.dart` and the host/client
/// wire model `lib/src/models/settings/app_settings_wire.g.dart` from the
/// settings table. From `packages/skotiq_core`, either of:
///
///     dart run tool/generate_app_settings.dart
///     SKOTIQ_REGENERATE=1 flutter test test/settings/app_settings_generated_test.dart
///
/// `--check` writes nothing and exits 1 when either file is stale. The table
/// and everything it imports must compile under plain Dart (no Flutter
/// library), or `dart run` fails inside the compiler.
library;

import 'dart:io';

import 'package:skotiq_core/src/settings/app_settings_table.dart';
import 'package:skotiq_core/src/settings/setting.dart';

const String kTablePath = 'lib/src/settings/app_settings_table.dart';
const String kGeneratedPath = 'lib/src/settings/app_settings_state.g.dart';
const String kWireGeneratedPath =
    'lib/src/models/settings/app_settings_wire.g.dart';

/// The `///` lines directly above each table entry, by field name.
Map<String, List<String>> _docsByField(String tableSource) {
  final docs = <String, List<String>>{};
  final entry = RegExp(
    r"^\s*\w+Setting(?:<\w+>)?\(\s*$|^\s*\w+Setting(?:<\w+>)?\('(\w+)'",
  );
  final name = RegExp(r"^\s*'(\w+)',");
  var pending = <String>[];
  var awaitingName = false;
  for (final line in tableSource.split('\n')) {
    final trimmed = line.trim();
    if (awaitingName) {
      final match = name.firstMatch(line);
      if (match != null) docs[match.group(1)!] = pending;
      pending = <String>[];
      awaitingName = false;
      continue;
    }
    if (trimmed.startsWith('///')) {
      pending.add(trimmed);
      continue;
    }
    final match = entry.firstMatch(line);
    if (match != null) {
      final field = match.group(1);
      if (field != null) {
        docs[field] = pending;
        pending = <String>[];
      } else {
        awaitingName = true;
      }
      continue;
    }
    pending = <String>[];
  }
  return docs;
}

String _handleType(Setting<Object?> setting) => switch (setting) {
  EnumSetting() => 'EnumSetting<${setting.dartType}>',
  _ => setting.runtimeType.toString(),
};

String generateAppSettingsState(String tableSource) {
  final docs = _docsByField(tableSource);
  final out = StringBuffer()
    ..writeln('// GENERATED from app_settings_table.dart by')
    ..writeln('// tool/generate_app_settings.dart. Do not edit: change the')
    ..writeln('// table and regenerate.')
    ..writeln()
    ..writeln('// dart format off')
    ..writeln()
    ..writeln(
      "import '../models/settings/app_settings_values.dart' show SafetyFailMode;",
    )
    ..writeln("import 'app_settings_table.dart';")
    ..writeln("import 'preflight_strictness.dart';")
    ..writeln("import 'setting.dart';")
    ..writeln()
    ..writeln('const Object _unset = Object();')
    ..writeln()
    ..writeln('/// The declared settings, by field name.')
    ..writeln('abstract final class AppSettingDefs {');
  for (var i = 0; i < kAppSettingsTable.length; i++) {
    final s = kAppSettingsTable[i];
    final type = _handleType(s);
    out.writeln(
      '  static final $type ${s.field} = kAppSettingsTable[$i] as $type;',
    );
  }
  final state = [
    for (final s in kAppSettingsTable)
      if (!s.heldNatively) s,
  ];
  out
    ..writeln('}')
    ..writeln()
    ..writeln('/// The application settings as one immutable value.')
    ..writeln('class AppSettingsState {');
  for (final s in state) {
    for (final line in docs[s.field] ?? const <String>[]) {
      out.writeln('  $line');
    }
    out.writeln('  final ${s.dartType} ${s.field};');
  }
  out
    ..writeln()
    ..writeln('  const AppSettingsState({');
  for (final s in state) {
    out.writeln(
      s.fallbackSource == 'null'
          ? '    this.${s.field},'
          : '    this.${s.field} = ${s.fallbackSource},',
    );
  }
  out
    ..writeln('  });')
    ..writeln()
    ..writeln(
      '  /// A copy with the given fields replaced. A nullable field is',
    )
    ..writeln('  /// cleared by passing null and kept by leaving it out.')
    ..writeln('  AppSettingsState copyWith({');
  for (final s in state) {
    out.writeln(
      s.isNullable
          ? '    Object? ${s.field} = _unset,'
          : '    ${s.dartType}? ${s.field},',
    );
  }
  out
    ..writeln('  }) {')
    ..writeln('    return AppSettingsState(');
  for (final s in state) {
    final f = s.field;
    out.writeln(
      s.isNullable
          ? '      $f: identical($f, _unset) ? this.$f : $f as ${s.dartType},'
          : '      $f: $f ?? this.$f,',
    );
  }
  out
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln('  /// The value of [setting].')
    ..writeln(
      '  T valueOf<T>(Setting<T> setting) => _read(setting.field) as T;',
    )
    ..writeln()
    ..writeln('  Object? _read(String field) => switch (field) {');
  for (final s in state) {
    out.writeln("    '${s.field}' => ${s.field},");
  }
  out
    ..writeln(
      "    _ => throw ArgumentError.value(field, 'field', 'not a setting'),",
    )
    ..writeln('  };')
    ..writeln()
    ..writeln('  /// A copy with [setting] set to [value].')
    ..writeln('  AppSettingsState withValue<T>(Setting<T> setting, T value) =>')
    ..writeln('      switch (setting.field) {');
  for (final s in state) {
    out.writeln(
      "        '${s.field}' => copyWith(${s.field}: value as ${s.dartType}),",
    );
  }
  out
    ..writeln(
      "        _ => throw ArgumentError.value(setting.field, 'setting'),",
    )
    ..writeln('      };')
    ..writeln()
    ..writeln('  /// A state built by asking [valueOf] for every setting.')
    ..writeln('  static AppSettingsState fromValues(')
    ..writeln('    Object? Function(Setting<Object?> setting) valueOf,')
    ..writeln('  ) {')
    ..writeln('    const t = kAppSettingsTable;')
    ..writeln('    return AppSettingsState(');
  for (var i = 0; i < kAppSettingsTable.length; i++) {
    final s = kAppSettingsTable[i];
    if (s.heldNatively) continue;
    out.writeln('      ${s.field}: valueOf(t[$i]) as ${s.dartType},');
  }
  out
    ..writeln('    );')
    ..writeln('  }')
    ..writeln('}');
  return out.toString();
}

/// One field of the wire model.
class _WireField {
  const _WireField({
    required this.name,
    required this.type,
    required this.defaultSource,
    required this.decode,
    this.encode,
    this.docs = const [],
  });

  final String name;

  /// The Dart type, nullable or not.
  final String type;

  /// Source of the value an absent key reads as; null for a nullable field
  /// without one.
  final String? defaultSource;

  /// Source reading the field from `json`.
  final String decode;

  /// Source writing the field, when it is not the value itself.
  final String? encode;
  final List<String> docs;

  bool get isNullable => type.endsWith('?');
  bool get isMap => type.startsWith('Map<');
}

/// Enums the wire model carries as themselves. Every other enum setting is
/// carried as its name, so the wire model depends on nothing beside it.
const Set<String> _wireEnums = {'SafetyFailMode'};

/// Fields of the settings document that no setting stands behind, in the
/// order the document lists them after the settings.
final List<_WireField> _documentOnlyFields = [
  _WireField(
    name: 'useSimulationMode',
    type: 'bool',
    defaultSource: 'false',
    decode: _scalar('useSimulationMode', 'bool', 'false'),
    docs: const [
      '/// Retired: simulation mode is not a shippable runtime state (the',
      '/// bundled native library is always a release build and refuses it).',
      '/// The field stays so stored and remote payloads that still carry it',
      '/// decode; nothing reads it.',
    ],
  ),
  for (final name in ['observer', 'telescope', 'instrument'])
    _WireField(
      name: name,
      type: 'String',
      defaultSource: "''",
      decode: _scalar(name, 'String', "''"),
    ),
  _WireField(
    name: 'updateCheckEnabled',
    type: 'bool',
    defaultSource: 'true',
    decode: _scalar('updateCheckEnabled', 'bool', 'true'),
  ),
  _WireField(
    name: 'updateServerUrl',
    type: 'String',
    defaultSource: "''",
    decode: _scalar('updateServerUrl', 'String', "''"),
  ),
  _WireField(
    name: 'updateChannel',
    type: 'String',
    defaultSource: "'stable'",
    decode: _scalar('updateChannel', 'String', "'stable'"),
  ),
  _WireField(
    name: 'updateCheckIntervalHours',
    type: 'int',
    defaultSource: '24',
    decode: _scalar('updateCheckIntervalHours', 'int', '24'),
  ),
  _WireField(
    name: 'skippedUpdateVersion',
    type: 'String',
    defaultSource: "''",
    decode: _scalar('skippedUpdateVersion', 'String', "''"),
  ),
  _WireField(
    name: 'mountSiteSyncMode',
    type: 'String',
    defaultSource: "'ask'",
    decode: _scalar('mountSiteSyncMode', 'String', "'ask'"),
    docs: const [
      '/// Always `ask` here: the setting travels through the host key/value',
      '/// store.',
    ],
  ),
];

String _scalar(String key, String type, String? fallback) {
  final read = switch (type.replaceAll('?', '')) {
    'int' => "(json['$key'] as num?)?.toInt()",
    'double' => "(json['$key'] as num?)?.toDouble()",
    _ => "json['$key'] as $type${type.endsWith('?') ? '' : '?'}",
  };
  return fallback == null ? read : '$read ?? $fallback';
}

String _mapLiteral<V>(Map<String, V> map, String valueType) {
  final entries = map.entries
      .map((e) => '${dartStringLiteral(e.key)}: ${e.value}')
      .join(', ');
  return 'const <String, $valueType>{$entries}';
}

_WireField _wireFieldOf(Setting<Object?> s, List<String> docs) {
  final key = s.wire;
  switch (s) {
    case EnumSetting() when _wireEnums.contains(s.dartType):
      final fallback = '${s.dartType}.${s.fallback.name}';
      return _WireField(
        name: key,
        type: s.dartType,
        defaultSource: fallback,
        decode:
            "\$enumDecodeNullable(_${_lowerFirst(s.dartType)}Names, "
            "json['$key']) ?? $fallback",
        encode: '_${_lowerFirst(s.dartType)}Names[$key]!',
        docs: docs,
      );
    case EnumSetting():
      final fallback = dartStringLiteral(s.fallback.name);
      return _WireField(
        name: key,
        type: 'String',
        defaultSource: fallback,
        decode: _scalar(key, 'String', fallback),
        docs: docs,
      );
    case BoolMapSetting(:final fallback):
      final literal = _mapLiteral(fallback, 'bool');
      return _WireField(
        name: key,
        type: s.dartType,
        defaultSource: literal,
        decode:
            "(json['$key'] as Map<String, dynamic>?)"
            '?.map((k, e) => MapEntry(k, e as bool)) ?? $literal',
        docs: docs,
      );
    case DoubleMapSetting(:final fallback):
      final literal = _mapLiteral(fallback, 'double');
      return _WireField(
        name: key,
        type: s.dartType,
        defaultSource: literal,
        decode:
            "(json['$key'] as Map<String, dynamic>?)"
            '?.map((k, e) => MapEntry(k, (e as num).toDouble())) ?? $literal',
        docs: docs,
      );
    case TextSetting(emptyWireIsFallback: true):
      // An empty value already reads as the setting's default.
      return _WireField(
        name: key,
        type: 'String',
        defaultSource: "''",
        decode: _scalar(key, 'String', "''"),
        docs: docs,
      );
    case BoolSetting() ||
        IntSetting() ||
        DoubleSetting() ||
        TextSetting() ||
        OptionalBoolSetting() ||
        OptionalIntSetting() ||
        OptionalDoubleSetting() ||
        OptionalTextSetting():
      // A setting with a "not set" state reads as not set when absent, so an
      // explicit null stays expressible.
      final fallback = s.isNullable ? null : s.fallbackSource;
      return _WireField(
        name: key,
        type: s.dartType,
        defaultSource: fallback,
        decode: _scalar(key, s.dartType, fallback),
        docs: docs,
      );
  }
}

String _lowerFirst(String name) => name[0].toLowerCase() + name.substring(1);

List<_WireField> _wireFields(String tableSource) {
  final docs = _docsByField(tableSource);
  return [
    const _WireField(
      name: 'location',
      type: 'ObserverLocation?',
      defaultSource: null,
      decode:
          "json['location'] == null ? null : "
          "ObserverLocation.fromJson(json['location'] as Map<String, dynamic>)",
    ),
    for (final s in kAppSettingsTable)
      if (s.sync == SettingSync.host)
        _wireFieldOf(s, docs[s.field] ?? const []),
    ..._documentOnlyFields,
  ];
}

String generateAppSettingsWire(String tableSource) {
  final fields = _wireFields(tableSource);
  final enums = {
    for (final f in fields)
      if (_wireEnums.contains(f.type)) f.type,
  };
  final out = StringBuffer()
    ..writeln('// GENERATED from app_settings_table.dart by')
    ..writeln('// tool/generate_app_settings.dart. Do not edit: change the')
    ..writeln('// table and regenerate.')
    ..writeln()
    ..writeln('// dart format off')
    ..writeln()
    ..writeln("import 'package:freezed_annotation/freezed_annotation.dart'")
    ..writeln(
      '    show DeepCollectionEquality, EqualUnmodifiableMapView, '
      '\$enumDecodeNullable;',
    )
    ..writeln()
    ..writeln("import 'app_settings_values.dart';")
    ..writeln()
    ..writeln('const Object _unset = Object();')
    ..writeln();
  for (final e in enums) {
    out.writeln(
      'final Map<$e, String> _${_lowerFirst(e)}Names = '
      '{for (final value in $e.values) value: value.name};',
    );
    out.writeln();
  }
  out
    ..writeln('/// The settings document a host and its linked clients')
    ..writeln('/// exchange: every setting the host keeps for them, by wire')
    ..writeln('/// name, and the fields no setting stands behind.')
    ..writeln('class AppSettings {')
    ..writeln('  const AppSettings({');
  for (final f in fields) {
    final param = f.isMap ? 'Map' : 'this.${f.name}';
    if (f.isMap) {
      out.writeln('    ${f.type} ${f.name} = ${f.defaultSource},');
    } else {
      out.writeln(
        f.defaultSource == null
            ? '    $param,'
            : '    $param = ${f.defaultSource},',
      );
    }
  }
  out.write('  })');
  final maps = fields.where((f) => f.isMap).toList();
  for (var i = 0; i < maps.length; i++) {
    out.write(
      '${i == 0 ? ' : ' : ',\n       '}_${maps[i].name} = ${maps[i].name}',
    );
  }
  out
    ..writeln(';')
    ..writeln()
    ..writeln('  factory AppSettings.fromJson(Map<String, dynamic> json) =>')
    ..writeln('      AppSettings(');
  for (final f in fields) {
    out.writeln('        ${f.name}: ${f.decode},');
  }
  out
    ..writeln('      );')
    ..writeln();
  for (final f in fields) {
    for (final line in f.docs) {
      out.writeln('  $line');
    }
    if (f.isMap) {
      out
        ..writeln('  final ${f.type} _${f.name};')
        ..writeln('  ${f.type} get ${f.name} {')
        ..writeln('    final value = _${f.name};')
        ..writeln('    if (value is EqualUnmodifiableMapView) return value;')
        ..writeln('    return EqualUnmodifiableMapView(value);')
        ..writeln('  }');
    } else {
      out.writeln('  final ${f.type} ${f.name};');
    }
  }
  out
    ..writeln()
    ..writeln('  /// Each field by wire name. [location] stays its model.')
    ..writeln('  Map<String, dynamic> toJson() => <String, dynamic>{');
  for (final f in fields) {
    out.writeln("    '${f.name}': ${f.encode ?? f.name},");
  }
  out
    ..writeln('  };')
    ..writeln()
    ..writeln(
      '  /// A copy with the given fields replaced. A nullable field is',
    )
    ..writeln('  /// cleared by passing null and kept by leaving it out.')
    ..writeln('  AppSettings copyWith({');
  for (final f in fields) {
    out.writeln(
      f.isNullable
          ? '    Object? ${f.name} = _unset,'
          : '    ${f.type}? ${f.name},',
    );
  }
  out
    ..writeln('  }) {')
    ..writeln('    return AppSettings(');
  for (final f in fields) {
    final n = f.name;
    out.writeln(
      f.isNullable
          ? '      $n: identical($n, _unset) ? this.$n : $n as ${f.type},'
          : '      $n: $n ?? this.$n,',
    );
  }
  out
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  bool operator ==(Object other) =>')
    ..writeln('      identical(this, other) ||')
    ..writeln('      (other.runtimeType == runtimeType &&')
    ..write('          other is AppSettings');
  for (final f in fields) {
    out.write(
      f.isMap
          ? ' &&\n          const DeepCollectionEquality().equals(other._${f.name}, _${f.name})'
          : ' &&\n          other.${f.name} == ${f.name}',
    );
  }
  out
    ..writeln(');')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  int get hashCode => Object.hashAll([')
    ..writeln('    runtimeType,');
  for (final f in fields) {
    out.writeln(
      f.isMap
          ? '    const DeepCollectionEquality().hash(_${f.name}),'
          : '    ${f.name},',
    );
  }
  out
    ..writeln('  ]);')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  String toString() =>')
    ..writeln("      'AppSettings('");
  for (var i = 0; i < fields.length; i++) {
    final n = fields[i].name;
    out.writeln(
      "      '$n: \$$n${i == fields.length - 1 ? ')' : ', '}'"
      '${i == fields.length - 1 ? ';' : ''}',
    );
  }
  out.writeln('}');
  return out.toString();
}

void writeAppSettingsWire() {
  File(kWireGeneratedPath).writeAsStringSync(
    generateAppSettingsWire(File(kTablePath).readAsStringSync()),
  );
}

void writeAppSettingsState() {
  File(kGeneratedPath).writeAsStringSync(
    generateAppSettingsState(File(kTablePath).readAsStringSync()),
  );
}

void main(List<String> args) {
  if (args.contains('--check')) {
    final table = File(kTablePath).readAsStringSync();
    for (final (path, expected) in [
      (kGeneratedPath, generateAppSettingsState(table)),
      (kWireGeneratedPath, generateAppSettingsWire(table)),
    ]) {
      if (File(path).readAsStringSync() != expected) {
        stderr.writeln('$path is stale; run without --check.');
        exitCode = 1;
      }
    }
    return;
  }
  writeAppSettingsState();
  writeAppSettingsWire();
}
