/// Writes the equipment-profile code that lists every field, from the field
/// table (`lib/src/models/equipment_profile_fields.dart`), between the
/// `BEGIN GENERATED equipment-profile <section>` and `END GENERATED` lines of
/// the files in [kProfileTargets]. From `packages/skotiq_core`, either of:
///
///     dart run tool/generate_equipment_profile.dart
///     SKOTIQ_REGENERATE=1 flutter test test/models/equipment_profile_fields_test.dart
///
/// `--check` writes nothing and exits 1 when a file is stale. The table must
/// compile under plain Dart (no Flutter or Drift import).
library;

import 'dart:io';

import 'package:skotiq_core/src/models/equipment_profile_fields.dart';

/// File path to the section it holds.
const Map<String, String> kProfileTargets = {
  'lib/src/models/equipment_profile_model.dart': 'model',
  'lib/src/models/equipment_profile.dart': 'wire',
  'lib/src/database/rows/equipment_profile_rows.dart': 'rows',
  'lib/src/database/rows/equipment_profile_remote_mapping.dart': 'remote',
  'lib/src/services/profile_service/profile_export_data.dart': 'export',
};

const String _begin = '// BEGIN GENERATED equipment-profile ';
const String _end = '// END GENERATED equipment-profile ';

String _snake(String name) => name.replaceAllMapped(
  RegExp('[A-Z]'),
  (m) => '_${m.group(0)!.toLowerCase()}',
);

String _capitalized(String name) =>
    '${name[0].toUpperCase()}${name.substring(1)}';

bool _isCollection(ProfileField f) =>
    f.kind == ProfileValueKind.filterNames ||
    f.kind == ProfileValueKind.focusOffsets;

String _scalarType(ProfileField f) => switch (f.kind) {
  ProfileValueKind.text => 'String',
  ProfileValueKind.real => 'double',
  ProfileValueKind.whole => 'int',
  ProfileValueKind.flag => 'bool',
  ProfileValueKind.filterNames => 'List<String>',
  ProfileValueKind.focusOffsets => 'Map<String, int>',
};

bool _modelNullable(ProfileField f) =>
    !f.required && f.fallback == null && !_isCollection(f);

/// The type in the domain model.
String _modelType(ProfileField f) =>
    _modelNullable(f) ? '${_scalarType(f)}?' : _scalarType(f);

/// The default in the domain model's constructor, or null.
String? _modelDefault(ProfileField f) => switch (f.kind) {
  ProfileValueKind.filterNames => 'const []',
  ProfileValueKind.focusOffsets => 'const {}',
  _ => f.fallback,
};

/// The type in the REST body and the stored row's text form.
String _wireType(ProfileField f) {
  if (_isCollection(f)) return 'String?';
  if (f.unsetWhenNotPositive) return 'double';
  return _modelType(f);
}

String? _wireDefault(ProfileField f) =>
    f.unsetWhenNotPositive ? '0.0' : (_isCollection(f) ? null : f.fallback);

String _jsonRead(String type, String key, String? fallback) {
  final raw = "json['$key']";
  final read = switch (type.replaceAll('?', '')) {
    'String' => '$raw as String?',
    'double' => '($raw as num?)?.toDouble()',
    'int' => '($raw as num?)?.toInt()',
    'bool' => '$raw as bool?',
    _ => throw ArgumentError(type),
  };
  if (fallback != null) return '$read ?? $fallback';
  if (!type.endsWith('?')) {
    return type == 'String' ? '$raw as String' : read;
  }
  return read;
}

Iterable<ProfileField> get _fields => kEquipmentProfileFields;

ProfileField _field(String name) => _fields.firstWhere((f) => f.name == name);

String _encode(ProfileField f, String value) =>
    _isCollection(f) ? '$value.isNotEmpty ? jsonEncode($value) : null' : value;

String _model() {
  final o = StringBuffer();
  o.writeln('  final int? id;');
  for (final f in _fields) {
    o.writeln('  final ${_modelType(f)} ${f.name};');
  }
  o
    ..writeln('  final bool isActive;')
    ..writeln('  final int sortOrder;')
    ..writeln('  final bool isDefault;')
    ..writeln('  final DateTime? createdAt;')
    ..writeln('  final DateTime? updatedAt;')
    ..writeln()
    ..writeln('  const EquipmentProfileModel({')
    ..writeln('    this.id,');
  for (final f in _fields) {
    final fallback = _modelDefault(f);
    o.writeln(
      f.required
          ? '    required this.${f.name},'
          : fallback == null
          ? '    this.${f.name},'
          : '    this.${f.name} = $fallback,',
    );
  }
  o
    ..writeln('    this.isActive = false,')
    ..writeln('    this.sortOrder = 0,')
    ..writeln('    this.isDefault = false,')
    ..writeln('    this.createdAt,')
    ..writeln('    this.updatedAt,')
    ..writeln('  });')
    ..writeln()
    ..writeln(
      '  /// A copy with the given fields replaced; a field left out or',
    )
    ..writeln('  /// passed null keeps its value.')
    ..writeln('  EquipmentProfileModel copyWith({')
    ..writeln('    int? id,');
  for (final f in _fields) {
    o.writeln('    ${_scalarType(f)}? ${f.name},');
    if (f.clearable) {
      o.writeln('    bool clear${_capitalized(f.name)} = false,');
    }
  }
  o
    ..writeln('    bool? isActive,')
    ..writeln('    int? sortOrder,')
    ..writeln('    bool? isDefault,')
    ..writeln('    DateTime? createdAt,')
    ..writeln('    DateTime? updatedAt,')
    ..writeln('  }) {')
    ..writeln('    return EquipmentProfileModel(')
    ..writeln('      id: id ?? this.id,');
  for (final f in _fields) {
    final n = f.name;
    o.writeln(
      f.clearable
          ? '      $n: clear${_capitalized(n)} ? null : ($n ?? this.$n),'
          : '      $n: $n ?? this.$n,',
    );
  }
  o
    ..writeln('      isActive: isActive ?? this.isActive,')
    ..writeln('      sortOrder: sortOrder ?? this.sortOrder,')
    ..writeln('      isDefault: isDefault ?? this.isDefault,')
    ..writeln('      createdAt: createdAt ?? this.createdAt,')
    ..writeln('      updatedAt: updatedAt ?? this.updatedAt,')
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln('  /// A new profile to insert with every field of this one and')
    ..writeln(
      '  /// [name]: no id (so the host or the DAO creates a row, where',
    )
    ..writeln(
      '  /// `copyWith(id: null)` would keep the id and rename this one),',
    )
    ..writeln('  /// neither active nor default, and fresh timestamps.')
    ..writeln(
      '  EquipmentProfileModel toInsertionCopy({required String name}) {',
    )
    ..writeln('    return EquipmentProfileModel(');
  for (final f in _fields) {
    o.writeln('      ${f.name}: ${f.name == 'name' ? 'name' : f.name},');
  }
  o
    ..writeln('      sortOrder: sortOrder,')
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln('  /// REST `/api/profiles` body for host-authoritative writes.')
    ..writeln('  remote_profile.EquipmentProfile toRemoteProfile() {')
    ..writeln('    return remote_profile.EquipmentProfile(')
    ..writeln("      id: id?.toString() ?? '',");
  for (final f in _fields) {
    final n = f.name;
    final value = f.unsetWhenNotPositive ? '$n ?? 0.0' : _encode(f, n);
    o.writeln('      $n: $value,');
  }
  o
    ..writeln('      sortOrder: sortOrder,')
    ..writeln('      isDefault: isDefault,')
    ..writeln('      createdAt: createdAt,')
    ..writeln('      updatedAt: updatedAt ?? DateTime.now(),')
    ..writeln('      isActive: isActive,')
    ..writeln('    );')
    ..writeln('  }');
  return o.toString();
}

/// The REST body's fields after the profile's: the stored row's flags and
/// timestamps and the camera's pixel size, which only the body carries.
const List<(String, String, String?)> _wireTail = [
  ('sortOrder', 'int', '0'),
  ('isDefault', 'bool', 'false'),
  ('createdAt', 'DateTime?', null),
  ('updatedAt', 'DateTime?', null),
  ('isActive', 'bool', 'false'),
  ('pixelSize', 'double?', null),
];

String _wire() {
  final all = <(String, String, String?)>[
    ('id', 'String', null),
    for (final f in _fields) (f.name, _wireType(f), _wireDefault(f)),
    ..._wireTail,
  ];
  bool required(String name) => name == 'id' || name == 'name';
  final o = StringBuffer()
    ..writeln('/// The REST `/api/profiles` body of an equipment profile.')
    ..writeln('class EquipmentProfile {')
    ..writeln('  const EquipmentProfile({');
  for (final (name, _, fallback) in all) {
    o.writeln(
      required(name)
          ? '    required this.$name,'
          : fallback == null
          ? '    this.$name,'
          : '    this.$name = $fallback,',
    );
  }
  o
    ..writeln('  });')
    ..writeln()
    ..writeln(
      '  factory EquipmentProfile.fromJson(Map<String, dynamic> json) =>',
    )
    ..writeln('      EquipmentProfile(');
  for (final (name, type, fallback) in all) {
    final value = type.startsWith('DateTime')
        ? "json['$name'] == null ? null : DateTime.parse(json['$name'] as String)"
        : _jsonRead(type, name, fallback);
    o.writeln('        $name: $value,');
  }
  o
    ..writeln('      );')
    ..writeln();
  for (final (name, type, _) in all) {
    o.writeln('  final $type $name;');
  }
  o
    ..writeln()
    ..writeln('  Map<String, dynamic> toJson() => <String, dynamic>{');
  for (final (name, type, _) in all) {
    o.writeln(
      type.startsWith('DateTime')
          ? "    '$name': $name?.toIso8601String(),"
          : "    '$name': $name,",
    );
  }
  o
    ..writeln('  };')
    ..writeln()
    ..writeln(
      '  /// A copy with the given fields replaced. A nullable field is',
    )
    ..writeln('  /// cleared by passing null and kept by leaving it out.')
    ..writeln('  EquipmentProfile copyWith({');
  for (final (name, type, _) in all) {
    o.writeln(
      type.endsWith('?') ? '    Object? $name = _unset,' : '    $type? $name,',
    );
  }
  o
    ..writeln('  }) {')
    ..writeln('    return EquipmentProfile(');
  for (final (name, type, _) in all) {
    o.writeln(
      type.endsWith('?')
          ? '      $name: identical($name, _unset) ? this.$name : $name as $type,'
          : '      $name: $name ?? this.$name,',
    );
  }
  o
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  bool operator ==(Object other) =>')
    ..writeln('      identical(this, other) ||')
    ..writeln('      (other is EquipmentProfile &&')
    ..writeln('          other.runtimeType == runtimeType');
  for (final (name, _, _) in all) {
    o.writeln('          && other.$name == $name');
  }
  o
    ..writeln('      );')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  int get hashCode => Object.hashAll([')
    ..writeln('    runtimeType,');
  for (final (name, _, _) in all) {
    o.writeln('    $name,');
  }
  o
    ..writeln('  ]);')
    ..writeln()
    ..writeln('  @override')
    ..writeln('  String toString() =>')
    ..writeln("      'EquipmentProfile('");
  for (var i = 0; i < all.length; i++) {
    final name = all[i].$1;
    final sep = i == all.length - 1 ? ')' : ', ';
    o.writeln("      '$name: \$$name$sep'");
  }
  o
    ..writeln('      ;')
    ..writeln('}');
  return o.toString();
}

String _rowRead(ProfileField f) {
  final n = f.name;
  if (_isCollection(f)) {
    final reader = f.kind == ProfileValueKind.filterNames
        ? '_storedFilterNames'
        : '_storedFocusOffsets';
    return "$reader(db.$n, field: '$n', column: '${_snake(n)}', profile: db.name)";
  }
  if (f.unsetWhenNotPositive) return '_positiveOrNull(db.$n)';
  final other = f.fallsBackTo;
  if (other != null) {
    final otherRead = _rowRead(_field(other));
    return 'db.$n > 0 ? db.$n : ($otherRead ?? ${f.fallback})';
  }
  return 'db.$n';
}

String _rows() {
  final o = StringBuffer()
    ..writeln('EquipmentProfileModel _profileFromRow(')
    ..writeln('  DbEquipmentProfile db, {')
    ..writeln('  required int? id,')
    ..writeln('  required DateTime? createdAt,')
    ..writeln('  required DateTime? updatedAt,')
    ..writeln('}) {')
    ..writeln('  return EquipmentProfileModel(')
    ..writeln('    id: id,');
  for (final f in _fields) {
    o.writeln('    ${f.name}: ${_rowRead(f)},');
  }
  o
    ..writeln('    isActive: db.isActive,')
    ..writeln('    sortOrder: db.sortOrder,')
    ..writeln('    isDefault: db.isDefault,')
    ..writeln('    createdAt: createdAt,')
    ..writeln('    updatedAt: updatedAt,')
    ..writeln('  );')
    ..writeln('}')
    ..writeln()
    ..writeln('extension EquipmentProfileModelRow on EquipmentProfileModel {')
    ..writeln('  /// The row a save of this profile writes.')
    ..writeln('  EquipmentProfilesCompanion toCompanion() {')
    ..writeln('    return EquipmentProfilesCompanion(')
    ..writeln('      id: id != null ? Value(id!) : const Value.absent(),');
  for (final f in _fields) {
    o.writeln('      ${f.name}: Value(${_encode(f, f.name)}),');
  }
  o
    ..writeln('      isActive: Value(isActive),')
    ..writeln('      sortOrder: Value(sortOrder),')
    ..writeln('      isDefault: Value(isDefault),')
    ..writeln('      updatedAt: Value(DateTime.now()),')
    ..writeln('    );')
    ..writeln('  }')
    ..writeln('}');
  return o.toString();
}

String _remote() {
  final o = StringBuffer()
    ..writeln('/// The REST body for a stored row (GET /api/profiles and the')
    ..writeln('/// active-profile endpoint).')
    ..writeln(
      'remote_profile.EquipmentProfile dbProfileToRemote(db.DbEquipmentProfile row) {',
    )
    ..writeln('  return remote_profile.EquipmentProfile(')
    ..writeln('    id: row.id.toString(),');
  for (final f in _fields) {
    final n = f.name;
    o.writeln(
      f.unsetWhenNotPositive ? '    $n: row.$n ?? 0.0,' : '    $n: row.$n,',
    );
  }
  o
    ..writeln('    sortOrder: row.sortOrder,')
    ..writeln('    isDefault: row.isDefault,')
    ..writeln('    createdAt: row.createdAt,')
    ..writeln('    updatedAt: row.updatedAt,')
    ..writeln('    isActive: row.isActive,')
    ..writeln('  );')
    ..writeln('}')
    ..writeln()
    ..writeln('/// The full stored row a REST body describes, for')
    ..writeln('/// `dao.updateProfile` (a full-row replace) and the linked')
    ..writeln("/// client's reading of the host's profiles.")
    ..writeln('///')
    ..writeln('/// With [existing] (the host update path) the sort order, the')
    ..writeln('/// default and active flags and `createdAt` stay the host')
    ..writeln("/// row's, so a client's save cannot reorder profiles or clear")
    ..writeln('/// the flags; those change through their own endpoints')
    ..writeln(
      '/// (`/api/profiles/<id>/default`, `/api/profiles/reorder`, load).',
    )
    ..writeln('/// A field the body omits that keeps the host value does so')
    ..writeln('/// too. Without it (the linked client) the body is carried')
    ..writeln("/// through, so the client's rows equal the host's.")
    ..writeln('db.DbEquipmentProfile remoteProfileToDbRow(')
    ..writeln('  remote_profile.EquipmentProfile profile, {')
    ..writeln('  db.DbEquipmentProfile? existing,')
    ..writeln('  DateTime? now,')
    ..writeln('}) {')
    ..writeln('  final writeStamp = now ?? DateTime.now().toUtc();')
    ..writeln('  return db.DbEquipmentProfile(')
    ..writeln('    id: int.tryParse(profile.id) ?? 0,');
  for (final f in _fields) {
    final n = f.name;
    o.writeln(
      f.keptWhenBodyOmits
          ? '    $n: profile.$n ?? existing?.$n,'
          : '    $n: profile.$n,',
    );
  }
  o
    ..writeln('    sortOrder: existing?.sortOrder ?? profile.sortOrder,')
    ..writeln('    isDefault: existing?.isDefault ?? profile.isDefault,')
    ..writeln('    isActive: existing?.isActive ?? profile.isActive,')
    ..writeln('    createdAt:')
    ..writeln('        existing?.createdAt ??')
    ..writeln('        profile.createdAt ??')
    ..writeln('        DateTime.fromMillisecondsSinceEpoch(0),')
    ..writeln('    updatedAt: profile.updatedAt ?? writeStamp,')
    ..writeln('  );')
    ..writeln('}');
  return o.toString();
}

String _exportRead(ProfileField f) {
  final n = f.name;
  final read = switch (f.kind) {
    ProfileValueKind.text => "_profileText(json['$n'], '$n')",
    ProfileValueKind.real => "_profileDouble(json['$n'], '$n')",
    ProfileValueKind.whole => "_profileInt(json['$n'], '$n')",
    ProfileValueKind.flag => "_profileBool(json['$n'], '$n')",
    ProfileValueKind.filterNames => "_profileStringList(json['$n'], '$n')",
    ProfileValueKind.focusOffsets => "_profileIntMap(json['$n'], '$n')",
  };
  final fallback = _modelDefault(f);
  return fallback == null ? read : '$read ?? $fallback';
}

String _export() {
  final o = StringBuffer()
    ..writeln('/// The export file entry for [profile]: its fields without the')
    ..writeln("/// stored row's id, flags and timestamps; an empty filter list")
    ..writeln('/// or offset map is written as null.')
    ..writeln(
      'Map<String, dynamic> _exportJsonOf(EquipmentProfileModel profile) {',
    )
    ..writeln('  return {');
  for (final f in _fields) {
    final n = f.name;
    o.writeln(
      _isCollection(f)
          ? "    '$n': profile.$n.isNotEmpty ? profile.$n : null,"
          : "    '$n': profile.$n,",
    );
  }
  o
    ..writeln('  };')
    ..writeln('}')
    ..writeln()
    ..writeln('/// The profile an export file entry describes, each field read')
    ..writeln('/// by its kind; [name] is the already checked name.')
    ..writeln('EquipmentProfileModel _profileFromExportJson(')
    ..writeln('  Map<String, dynamic> json, {')
    ..writeln('  required String name,')
    ..writeln('}) {')
    ..writeln('  return EquipmentProfileModel(');
  for (final f in _fields) {
    o.writeln(
      f.name == 'name'
          ? '    name: name,'
          : '    ${f.name}: ${_exportRead(f)},',
    );
  }
  o
    ..writeln('  );')
    ..writeln('}');
  return o.toString();
}

String _section(String name) => switch (name) {
  'model' => _model(),
  'wire' => _wire(),
  'rows' => _rows(),
  'remote' => _remote(),
  'export' => _export(),
  _ => throw ArgumentError.value(name, 'section'),
};

/// [source] with its generated section replaced.
String regenerateProfileSection(String source, String section) {
  final lines = source.split('\n');
  final start = lines.indexWhere((l) => l.trim() == '$_begin$section');
  final end = lines.indexWhere((l) => l.trim() == '$_end$section');
  if (start < 0 || end < start) {
    throw StateError('no "$_begin$section" ... "$_end$section" markers');
  }
  final indent = lines[start].substring(
    0,
    lines[start].length - lines[start].trimLeft().length,
  );
  final body = _section(section).trimRight();
  return [
    ...lines.sublist(0, start + 1),
    '$indent// dart format off',
    body,
    '$indent// dart format on',
    ...lines.sublist(end),
  ].join('\n');
}

/// Paths whose generated section is stale.
List<String> staleProfileTargets() => [
  for (final MapEntry(key: path, value: section) in kProfileTargets.entries)
    if (File(path).readAsStringSync() !=
        regenerateProfileSection(File(path).readAsStringSync(), section))
      path,
];

void writeProfileTargets() {
  for (final MapEntry(key: path, value: section) in kProfileTargets.entries) {
    final file = File(path);
    file.writeAsStringSync(
      regenerateProfileSection(file.readAsStringSync(), section),
    );
  }
}

void main(List<String> args) {
  if (args.contains('--check')) {
    final stale = staleProfileTargets();
    for (final path in stale) {
      stderr.writeln('$path is stale; run without --check.');
    }
    if (stale.isNotEmpty) exitCode = 1;
    return;
  }
  writeProfileTargets();
}
