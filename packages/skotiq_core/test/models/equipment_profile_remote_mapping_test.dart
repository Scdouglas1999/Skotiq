import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;
import 'package:skotiq_core/src/models/equipment_profile_remote_mapping.dart';

/// The canonical equipment-profile converter is lossless for every field the
/// slave's equipment cards need, `meridianFlipOverrides`, `safetyMonitorName`
/// and `switchName` included. These tests also lock in the
/// preserve-from-existing guard so a slave-shaped save can never silently wipe
/// host-side meridian overrides / flags.
db.EquipmentProfile _sampleRow({
  int id = 7,
  String? meridianFlipOverrides = '{"enabled":true,"flipAtDeg":1.5}',
  String? safetyMonitorName = 'My Safety',
  String? switchName = 'Power Box',
  bool isDefault = true,
  int sortOrder = 3,
  bool isActive = true,
}) {
  return db.EquipmentProfile(
    id: id,
    name: 'Rig A',
    description: 'desc',
    cameraId: 'native:zwo:0',
    mountId: 'native:eqmod:0',
    focuserId: null,
    filterWheelId: null,
    guiderId: null,
    rotatorId: null,
    domeId: null,
    weatherId: null,
    safetyMonitorId: 'ascom:safety:0',
    switchId: 'ascom:switch:0',
    coverCalibratorId: null,
    focalLength: 600.0,
    aperture: 80.0,
    focalRatio: 7.5,
    defaultGain: 100,
    defaultOffset: 30,
    defaultBinX: 1,
    defaultBinY: 1,
    defaultCoolingTemp: -10.0,
    coolOnConnect: true,
    defaultCenteringExposure: 5.0,
    filterNames: '["L","R","G","B"]',
    filterFocusOffsets: '{"L":0,"R":12}',
    meridianFlipOverrides: meridianFlipOverrides,
    cameraName: 'ASI2600',
    mountName: 'EQ6-R',
    focuserName: null,
    filterWheelName: null,
    guiderName: null,
    rotatorName: null,
    safetyMonitorName: safetyMonitorName,
    switchName: switchName,
    telescopeName: 'ED80',
    telescopeFocalLength: 600.0,
    telescopeAperture: 80.0,
    profileIcon: 'telescope',
    profileColor: 0xFF00FF00,
    sortOrder: sortOrder,
    isDefault: isDefault,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 6, 1),
    isActive: isActive,
  );
}

void main() {
  group('equipment_profile_remote_mapping override + name fields', () {
    test(
      'db -> remote -> db round-trips meridianFlipOverrides / safetyMonitorName / switchName',
      () {
        final row = _sampleRow();
        final remote = dbProfileToRemote(row);

        // The wire model carries all three fields.
        expect(remote.meridianFlipOverrides, row.meridianFlipOverrides);
        expect(remote.safetyMonitorName, row.safetyMonitorName);
        expect(remote.switchName, row.switchName);

        // Slave-poll path (existing == null): values carried through unchanged.
        final back = remoteProfileToDbRow(remote);
        expect(back.meridianFlipOverrides, row.meridianFlipOverrides);
        expect(back.safetyMonitorName, row.safetyMonitorName);
        expect(back.switchName, row.switchName);
      },
    );

    test('remote -> companion carries the new name fields', () {
      final remote = dbProfileToRemote(_sampleRow());
      final companion = remoteProfileToCompanion(remote);

      expect(companion.safetyMonitorName.value, 'My Safety');
      expect(companion.switchName.value, 'Power Box');
      expect(
        companion.meridianFlipOverrides.value,
        '{"enabled":true,"flipAtDeg":1.5}',
      );
    });

    test(
      'a slave-shaped save (overrides null) preserves host meridian overrides',
      () {
        // Host row has overrides set.
        final existing = _sampleRow(
          meridianFlipOverrides: '{"enabled":true,"flipAtDeg":2.0}',
        );

        // Slave POSTs a payload with meridianFlipOverrides == null (e.g. an
        // older client or a field simply omitted): must NOT wipe the host value.
        final slavePayload = dbProfileToRemote(
          existing,
        ).copyWith(meridianFlipOverrides: null);

        final merged = remoteProfileToDbRow(slavePayload, existing: existing);
        expect(
          merged.meridianFlipOverrides,
          '{"enabled":true,"flipAtDeg":2.0}',
        );
      },
    );

    test(
      'a slave that explicitly changes meridian overrides now writes the new value',
      () {
        final existing = _sampleRow(
          meridianFlipOverrides: '{"enabled":true,"flipAtDeg":2.0}',
        );
        final slavePayload = dbProfileToRemote(
          existing,
        ).copyWith(meridianFlipOverrides: '{"enabled":false}');

        final merged = remoteProfileToDbRow(slavePayload, existing: existing);
        expect(merged.meridianFlipOverrides, '{"enabled":false}');
      },
    );

    test(
      'host update path preserves isDefault / sortOrder / isActive from existing row',
      () {
        final existing = _sampleRow(
          isDefault: true,
          sortOrder: 3,
          isActive: true,
        );
        // Slave attempts to flip default/order/active via an ordinary save.
        final slavePayload = remote_profile.EquipmentProfile(
          id: existing.id.toString(),
          name: existing.name,
          isDefault: false,
          sortOrder: 99,
          isActive: false,
        );

        final merged = remoteProfileToDbRow(slavePayload, existing: existing);
        expect(merged.isDefault, isTrue, reason: 'default preserved');
        expect(merged.sortOrder, 3, reason: 'sort order preserved');
        expect(merged.isActive, isTrue, reason: 'active preserved');
      },
    );
  });
}
