/// Writes `lib/src/settings/app_settings_state.g.dart` from the settings
/// table. Run through the test that checks the file is current:
///
///     SKOTIQ_REGENERATE=1 flutter test test/settings/app_settings_generated_test.dart
library;

import 'dart:io';

import 'package:skotiq_core/src/settings/app_settings_table.dart';
import 'package:skotiq_core/src/settings/setting.dart';

const String kTablePath = 'lib/src/settings/app_settings_table.dart';
const String kGeneratedPath = 'lib/src/settings/app_settings_state.g.dart';

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
      "import '../models/settings/app_settings.dart' show SafetyFailMode;",
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
  out
    ..writeln('}')
    ..writeln()
    ..writeln('/// The application settings as one immutable value.')
    ..writeln('class AppSettingsState {');
  for (final s in kAppSettingsTable) {
    for (final line in docs[s.field] ?? const <String>[]) {
      out.writeln('  $line');
    }
    out.writeln('  final ${s.dartType} ${s.field};');
  }
  out
    ..writeln()
    ..writeln('  const AppSettingsState({');
  for (final s in kAppSettingsTable) {
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
  for (final s in kAppSettingsTable) {
    out.writeln(
      s.isNullable
          ? '    Object? ${s.field} = _unset,'
          : '    ${s.dartType}? ${s.field},',
    );
  }
  out
    ..writeln('  }) {')
    ..writeln('    return AppSettingsState(');
  for (final s in kAppSettingsTable) {
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
  for (final s in kAppSettingsTable) {
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
  for (final s in kAppSettingsTable) {
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
    out.writeln('      ${s.field}: valueOf(t[$i]) as ${s.dartType},');
  }
  out
    ..writeln('    );')
    ..writeln('  }')
    ..writeln('}');
  return out.toString();
}

void writeAppSettingsState() {
  File(kGeneratedPath).writeAsStringSync(
    generateAppSettingsState(File(kTablePath).readAsStringSync()),
  );
}
