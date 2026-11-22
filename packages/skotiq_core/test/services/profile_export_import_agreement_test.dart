// Exporting all profiles writes each one as exporting it alone does.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/profile_service.dart';

import '../harness/in_memory_database.dart';

final _service = Provider<ProfileService>((ref) => ProfileService(ref));

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  return container;
}

/// Optics only in the telescope columns and an empty stored filter list, as
/// rows written by older builds hold them.
db.DbEquipmentProfile _olderRow() => db.DbEquipmentProfile(
  id: 4,
  name: 'Older rig',
  focalLength: 0.0,
  aperture: 0.0,
  telescopeFocalLength: 800.0,
  telescopeAperture: 0.0,
  filterNames: '[]',
  defaultBinX: 1,
  defaultBinY: 1,
  coolOnConnect: false,
  sortOrder: 0,
  isDefault: false,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  isActive: false,
);

Map<String, Object?> _onlyProfile(String document) =>
    ((jsonDecode(document) as Map)['profiles'] as List).single
        as Map<String, Object?>;

void main() {
  test('exporting all writes a profile as exporting it alone does', () async {
    final container = _container();
    final database = container.read(databaseProvider);
    await database.into(database.equipmentProfiles).insert(_olderRow());
    final service = container.read(_service);

    final all = _onlyProfile(await service.exportAllProfilesToJson());
    final one = _onlyProfile(await service.exportProfileToJson(4));

    expect(all, one);
    expect(all['focalLength'], 800.0);
  });
}
