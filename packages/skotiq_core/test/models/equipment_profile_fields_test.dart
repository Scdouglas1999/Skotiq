import 'dart:io';

import 'package:drift/drift.dart' show DriftSqlType;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/equipment_profile_fields.dart';

import '../../tool/generate_equipment_profile.dart';

/// The stored row's own columns, which no profile shape describes the same
/// way and so are not table entries.
const _rowColumns = {
  'id',
  'is_active',
  'is_default',
  'sort_order',
  'created_at',
  'updated_at',
};

String _snake(String name) => name.replaceAllMapped(
  RegExp('[A-Z]'),
  (m) => '_${m.group(0)!.toLowerCase()}',
);

void main() {
  test('the generated profile code matches the field table', () {
    if (Platform.environment['SKOTIQ_REGENERATE'] == '1') {
      writeProfileTargets();
    }
    expect(
      staleProfileTargets(),
      isEmpty,
      reason:
          'The profile field table changed. Regenerate with '
          'SKOTIQ_REGENERATE=1 flutter test '
          'test/models/equipment_profile_fields_test.dart',
    );
  });

  test(
    'the generator runs under plain Dart',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tool/generate_equipment_profile.dart',
        '--check',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('every declared field has its column and every column a field', () {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final columns = {
      for (final column in database.equipmentProfiles.$columns)
        column.name: column,
    };

    final declared = {for (final f in kEquipmentProfileFields) _snake(f.name)};
    expect(declared.length, kEquipmentProfileFields.length);
    expect(
      {...declared, ..._rowColumns},
      columns.keys.toSet(),
      reason: 'a field without a column, or a column without a field',
    );

    for (final field in kEquipmentProfileFields) {
      final column = columns[_snake(field.name)]!;
      final type = switch (field.kind) {
        ProfileValueKind.text ||
        ProfileValueKind.filterNames ||
        ProfileValueKind.focusOffsets => DriftSqlType.string,
        ProfileValueKind.real => DriftSqlType.double,
        ProfileValueKind.whole => DriftSqlType.int,
        ProfileValueKind.flag => DriftSqlType.bool,
      };
      expect(column.type, type, reason: field.name);
      final nullable =
          !field.required &&
          (field.fallback == null || field.unsetWhenNotPositive);
      expect(column.$nullable, nullable, reason: field.name);
    }
  });
}
