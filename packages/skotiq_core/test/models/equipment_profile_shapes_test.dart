// What every equipment-profile shape makes of the same stored rows: the
// domain model, the REST body, the stored row a body becomes, the row a save
// writes, the export file and what an import stores.
//
// The snapshot is `test/fixtures/equipment_profile/shapes.json`. Regenerate it
// only for an intended change, with
// `SKOTIQ_REGENERATE=1 flutter test test/models/equipment_profile_shapes_test.dart`.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Insertable, Variable, Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/database/rows/equipment_profile_remote_mapping.dart';
import 'package:skotiq_core/src/database/rows/equipment_profile_rows.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;
import 'package:skotiq_core/src/models/equipment_profile_model.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/profile_service.dart';

import '../harness/in_memory_database.dart';

const _snapshotPath = 'test/fixtures/equipment_profile/shapes.json';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

final _created = DateTime.utc(2026, 1, 2, 3, 4, 5);
final _updated = DateTime.utc(2026, 6, 7, 8, 9, 10);
final _writeClock = DateTime.utc(2026, 11, 1);

db.DbEquipmentProfile _fullRow() => db.DbEquipmentProfile(
  id: 7,
  name: 'Full Rig',
  description: 'every column set',
  cameraId: 'cam-id',
  mountId: 'mount-id',
  focuserId: 'focuser-id',
  filterWheelId: 'wheel-id',
  guiderId: 'guider-id',
  guideCameraId: 'guide-cam-id',
  rotatorId: 'rotator-id',
  domeId: 'dome-id',
  weatherId: 'weather-id',
  safetyMonitorId: 'safety-id',
  switchId: 'switch-id',
  coverCalibratorId: 'cover-id',
  focalLength: 440.0,
  aperture: 80.0,
  focalRatio: 5.5,
  defaultGain: 101,
  defaultOffset: 31,
  defaultReadoutMode: 'High Gain',
  defaultBinX: 2,
  defaultBinY: 3,
  defaultCoolingTemp: -12.5,
  coolOnConnect: true,
  defaultCenteringExposure: 4.5,
  filterNames: '["L","R","G"]',
  filterFocusOffsets: '{"L":0,"R":-12}',
  meridianFlipOverrides: '{"enabled":true}',
  cameraName: 'cam-name',
  mountName: 'mount-name',
  focuserName: 'focuser-name',
  filterWheelName: 'wheel-name',
  guiderName: 'guider-name',
  guideCameraName: 'guide-cam-name',
  rotatorName: 'rotator-name',
  safetyMonitorName: 'safety-name',
  switchName: 'switch-name',
  telescopeName: 'scope-name',
  telescopeFocalLength: 550.0,
  telescopeAperture: 80.0,
  guideFocalLength: 120.0,
  profileIcon: 'telescope',
  profileColor: 0xFF112233,
  sortOrder: 4,
  isDefault: true,
  createdAt: _created,
  updatedAt: _updated,
  isActive: true,
);

db.DbEquipmentProfile _emptyRow() => db.DbEquipmentProfile(
  id: 8,
  name: 'Empty',
  focalLength: 0.0,
  aperture: 0.0,
  defaultBinX: 1,
  defaultBinY: 1,
  coolOnConnect: false,
  sortOrder: 0,
  isDefault: false,
  createdAt: _created,
  updatedAt: _updated,
  isActive: false,
);

/// Optics only in the telescope columns, an empty filter list and damaged
/// focus offsets.
db.DbEquipmentProfile _legacyTelescopeRow() => db.DbEquipmentProfile(
  id: 9,
  name: 'Legacy telescope',
  focalLength: 0.0,
  aperture: 0.0,
  telescopeFocalLength: 800.0,
  telescopeAperture: 100.0,
  filterNames: '[]',
  filterFocusOffsets: '{bad',
  defaultBinX: 1,
  defaultBinY: 1,
  coolOnConnect: false,
  sortOrder: 1,
  isDefault: false,
  createdAt: _created,
  updatedAt: _updated,
  isActive: false,
);

/// Zero telescope columns and damaged filter names.
db.DbEquipmentProfile _zeroTelescopeRow() => db.DbEquipmentProfile(
  id: 10,
  name: 'Zero telescope',
  focalLength: 500.0,
  aperture: 100.0,
  telescopeFocalLength: 0.0,
  telescopeAperture: 0.0,
  filterNames: 'not json',
  filterFocusOffsets: '{}',
  defaultBinX: 1,
  defaultBinY: 1,
  coolOnConnect: false,
  sortOrder: 2,
  isDefault: false,
  createdAt: _created,
  updatedAt: _updated,
  isActive: false,
);

Map<String, db.DbEquipmentProfile Function()> _rows() => {
  'full': _fullRow,
  'empty': _emptyRow,
  'legacyTelescope': _legacyTelescopeRow,
  'zeroTelescope': _zeroTelescopeRow,
};

Object? _plain(Object? value) => switch (value) {
  DateTime() => value.toUtc().toIso8601String(),
  Map() => {
    for (final entry in value.entries) '${entry.key}': _plain(entry.value),
  },
  List() => [for (final item in value) _plain(item)],
  _ => value,
};

Object? _sortedKeys(Object? value) => switch (value) {
  Map() => {
    for (final key in value.keys.map((k) => '$k').toList()..sort())
      key: _sortedKeys(value[key]),
  },
  List() => [for (final item in value) _sortedKeys(item)],
  _ => value,
};

Map<String, Object?> _describeModel(EquipmentProfileModel p) => {
  'id': p.id,
  'name': p.name,
  'description': p.description,
  'isActive': p.isActive,
  'cameraId': p.cameraId,
  'mountId': p.mountId,
  'focuserId': p.focuserId,
  'filterWheelId': p.filterWheelId,
  'guiderId': p.guiderId,
  'guideCameraId': p.guideCameraId,
  'guideFocalLength': p.guideFocalLength,
  'rotatorId': p.rotatorId,
  'domeId': p.domeId,
  'weatherId': p.weatherId,
  'safetyMonitorId': p.safetyMonitorId,
  'switchId': p.switchId,
  'coverCalibratorId': p.coverCalibratorId,
  'cameraName': p.cameraName,
  'mountName': p.mountName,
  'focuserName': p.focuserName,
  'filterWheelName': p.filterWheelName,
  'guiderName': p.guiderName,
  'guideCameraName': p.guideCameraName,
  'rotatorName': p.rotatorName,
  'safetyMonitorName': p.safetyMonitorName,
  'switchName': p.switchName,
  'telescopeName': p.telescopeName,
  'telescopeFocalLength': p.telescopeFocalLength,
  'telescopeAperture': p.telescopeAperture,
  'focalLength': p.focalLength,
  'aperture': p.aperture,
  'focalRatio': p.focalRatio,
  'defaultGain': p.defaultGain,
  'defaultOffset': p.defaultOffset,
  'defaultReadoutMode': p.defaultReadoutMode,
  'defaultBinX': p.defaultBinX,
  'defaultBinY': p.defaultBinY,
  'defaultCoolingTemp': p.defaultCoolingTemp,
  'coolOnConnect': p.coolOnConnect,
  'defaultCenteringExposure': p.defaultCenteringExposure,
  'filterNames': p.filterNames,
  'filterFocusOffsets': p.filterFocusOffsets,
  'meridianFlipOverrides': p.meridianFlipOverrides,
  'profileIcon': p.profileIcon,
  'profileColor': p.profileColor,
  'sortOrder': p.sortOrder,
  'isDefault': p.isDefault,
  'createdAt': p.createdAt,
  'updatedAt': p.updatedAt,
};

/// The values an insert or update would write, by SQL column; `updated_at`
/// left out where it is the wall clock.
Map<String, Object?> _describeInsertable(
  Insertable<db.DbEquipmentProfile> row, {
  bool clockStamped = false,
}) {
  final columns = row.toColumns(false);
  return {
    for (final entry in columns.entries)
      if (!(clockStamped && entry.key == 'updated_at'))
        entry.key: switch (entry.value) {
          final Variable variable => _plain(variable.value),
          final other => '$other',
        },
  };
}

Map<String, Object?> _describeRow(db.DbEquipmentProfile row) =>
    _describeInsertable(row.toCompanion(false));

Map<String, Object?> _wireJson(remote_profile.EquipmentProfile profile) =>
    profile.toJson();

ProviderContainer _localContainer() {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  return container;
}

final _localService = Provider<ProfileService>((ref) => ProfileService(ref));

Future<void> _insertRows(ProviderContainer container) async {
  final database = container.read(databaseProvider);
  for (final make in _rows().values) {
    await database.into(database.equipmentProfiles).insert(make());
  }
}

Map<String, Object?> _maskExportDate(String json) {
  final doc = jsonDecode(json) as Map<String, dynamic>;
  doc['exportDate'] = '<now>';
  return doc;
}

/// An export file written by every build up to 6.1.0: a bare field map.
const Map<String, Object?> _legacyBareExport = {
  'name': 'Bare legacy',
  'focalLength': 600,
  'aperture': 120,
  'defaultBinX': 1,
  'defaultBinY': 1,
  'coolOnConnect': false,
  'filterNames': ['Ha', 'OIII'],
  'filterFocusOffsets': {'Ha': 4},
  'telescopeFocalLength': 0,
};

/// A pre-envelope batch export with an empty filter list and fields this
/// build does not know.
const Map<String, Object?> _legacyBatchExport = {
  'version': 2,
  'profiles': [
    {
      'name': 'Batch one',
      'focalLength': 1000.0,
      'aperture': 200.0,
      'filterNames': <String>[],
      'filterFocusOffsets': <String, int>{},
      'defaultGain': 120.7,
      'meridianFlipOverrides': '{"pauseBefore":5}',
      'unknownField': 'ignored',
    },
    {
      'name': 'Batch two',
      'focalLength': 0,
      'aperture': 0,
      'telescopeFocalLength': 400,
      'telescopeAperture': 80,
      'guideCameraId': 'gcam',
      'guideFocalLength': 160,
      'defaultReadoutMode': 'Low Noise',
    },
  ],
};

Future<Map<String, Object?>> _snapshot() async {
  final out = <String, Object?>{};

  for (final MapEntry(key: label, value: make) in _rows().entries) {
    final row = make();
    final model = row.toModel();
    final wire = dbProfileToRemote(row);
    out[label] = {
      'model': _plain(_describeModel(model)),
      'wire': _plain(_wireJson(wire)),
      'modelToWire': _plain(_wireJson(model.toRemoteProfile())),
      'modelToCompanion': _describeInsertable(
        model.toCompanion(),
        clockStamped: true,
      ),
      'wireToRow': _describeRow(remoteProfileToDbRow(wire, now: _writeClock)),
      'wireToRowOverExisting': _describeRow(
        remoteProfileToDbRow(
          wire.copyWith(
            meridianFlipOverrides: null,
            isDefault: !wire.isDefault,
            isActive: !wire.isActive,
            sortOrder: wire.sortOrder + 10,
            createdAt: null,
          ),
          existing: _fullRow(),
          now: _writeClock,
        ),
      ),
      'wireToCompanion': _describeInsertable(remoteProfileToCompanion(wire)),
      'wireToModel': _plain(_describeModel(equipmentProfileFromRemote(wire))),
      'insertionCopy': _plain(
        _describeModel(model.toInsertionCopy(name: 'Copy')),
      ),
      'exportFromModel': _plain(ProfileExportData.fromModel(model).toJson()),
      'exportRoundTrip': _plain(
        ProfileExportData.fromJson(
          ProfileExportData.fromModel(model).toJson(),
        ).toJson(),
      ),
    };
  }

  out['wireDefaults'] = _plain(
    remote_profile.EquipmentProfile.fromJson(const {
      'id': '3',
      'name': 'Minimal',
    }).toJson(),
  );
  out['wireWithPixelSize'] = _plain(
    remote_profile.EquipmentProfile.fromJson(const {
      'id': '3',
      'name': 'Pixel',
      'pixelSize': 3.76,
      'telescopeFocalLength': 250,
      'defaultGain': 100.0,
    }).toJson(),
  );

  final exports = _localContainer();
  await _insertRows(exports);
  final exportService = exports.read(_localService);
  out['localExportAll'] = _maskExportDate(
    await exportService.exportAllProfilesToJson(),
  );
  out['localExportOne'] = {
    for (final MapEntry(key: label, value: make) in _rows().entries)
      label: _maskExportDate(
        await exportService.exportProfileToJson(make().id),
      ),
  };

  final documents = {
    'bare': jsonEncode(_legacyBareExport),
    'batch': jsonEncode(_legacyBatchExport),
    'roundTrip': out['localExportAll'] == null
        ? ''
        : jsonEncode(out['localExportAll']),
  };

  final localImports = <String, Object?>{};
  for (final MapEntry(key: label, value: document) in documents.entries) {
    final container = _localContainer();
    final ids = await container
        .read(_localService)
        .importAllProfilesFromJson(document);
    final database = container.read(databaseProvider);
    final stored = <Object?>[];
    for (final id in ids) {
      final row = await (database.select(
        database.equipmentProfiles,
      )..where((p) => p.id.equals(id))).getSingle();
      final described = _describeRow(row)
        ..remove('created_at')
        ..remove('updated_at');
      stored.add(described);
    }
    localImports[label] = stored;
  }
  out['localImport'] = localImports;

  final hostImports = <String, Object?>{};
  for (final MapEntry(key: label, value: document) in documents.entries) {
    final host = _MockNetworkBackend();
    final saved = <Map<String, Object?>>[];
    when(() => host.getProfiles()).thenAnswer((_) async => const []);
    when(() => host.saveProfile(any())).thenAnswer((invocation) async {
      final profile =
          invocation.positionalArguments.single
              as remote_profile.EquipmentProfile;
      saved.add(
        Map<String, Object?>.from(_wireJson(profile))..remove('updatedAt'),
      );
    });
    when(() => host.lastSavedProfileId).thenReturn('5');
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final service = container.read(
      Provider<ProfileService>(
        (ref) => ProfileService(ref, hostProfiles: host),
      ),
    );
    await service.importAllProfilesFromJson(document);
    hostImports[label] = saved;
  }
  out['hostImport'] = hostImports;

  return out;
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      const remote_profile.EquipmentProfile(id: '0', name: 'fallback'),
    );
  });

  test('every profile shape matches the snapshot', () async {
    // Key order is not part of any shape, so the snapshot sorts it.
    final actual = const JsonEncoder.withIndent(
      '  ',
    ).convert(_sortedKeys(await _snapshot()));
    final file = File(_snapshotPath);
    if (Platform.environment['SKOTIQ_REGENERATE'] == '1') {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$actual\n');
    }
    expect(actual, file.readAsStringSync().trimRight());
  });

  test('a stored row keeps the values Drift gave it', () {
    // Guards the snapshot's own reading of rows: a Value.absent() here would
    // drop a column from every description above.
    expect(
      _fullRow().toCompanion(false).focalLength,
      const Value<double>(440.0),
    );
  });
}
