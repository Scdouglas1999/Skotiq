import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;
import 'package:skotiq_core/src/providers/profiles_provider.dart';

/// The slave-side UI model [EquipmentProfileModel] round-trips every field the
/// slave edits losslessly through the REST wire model in BOTH directions —
/// `toRemoteProfile()` (slave -> host POST) and `fromRemoteProfile()` (host GET
/// -> slave UI). `meridianFlipOverrides`, `safetyMonitorName` and `switchName`
/// survive the round-trip, so the converter's preserve-from-existing guard is
/// not the only thing protecting them: an explicit slave edit travels the wire
/// as a real value.
EquipmentProfileModel _sampleModel({
  String? meridianFlipOverrides = '{"enabled":true,"flipAtDeg":1.5}',
  String? safetyMonitorName = 'My Safety',
  String? switchName = 'Power Box',
}) {
  return EquipmentProfileModel(
    id: 11,
    name: 'Slave Rig',
    description: 'edited on slave',
    isActive: true,
    cameraId: 'native:zwo:0',
    mountId: 'native:eqmod:0',
    focuserId: 'native:focuser:0',
    filterWheelId: 'native:efw:0',
    guiderId: 'native:guider:0',
    rotatorId: 'native:rotator:0',
    domeId: 'ascom:dome:0',
    weatherId: 'ascom:weather:0',
    safetyMonitorId: 'ascom:safety:0',
    switchId: 'ascom:switch:0',
    coverCalibratorId: 'ascom:cover:0',
    cameraName: 'ASI2600',
    mountName: 'EQ6-R',
    focuserName: 'EAF',
    filterWheelName: 'EFW',
    guiderName: 'OAG',
    rotatorName: 'Falcon',
    safetyMonitorName: safetyMonitorName,
    switchName: switchName,
    telescopeName: 'ED80',
    telescopeFocalLength: 600.0,
    telescopeAperture: 80.0,
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
    filterNames: const ['L', 'R', 'G', 'B'],
    filterFocusOffsets: const {'L': 0, 'R': 12},
    meridianFlipOverrides: meridianFlipOverrides,
    profileIcon: 'telescope',
    profileColor: 0xFF00FF00,
    sortOrder: 3,
    isDefault: true,
  );
}

void main() {
  group('EquipmentProfileModel REST round-trip (slave UI model)', () {
    test('toRemoteProfile -> fromRemoteProfile preserves the override + name '
        'fields', () {
      final model = _sampleModel();
      final wire = model.toRemoteProfile();

      // The wire model carries the slave's explicit values (not null).
      expect(wire.meridianFlipOverrides, model.meridianFlipOverrides);
      expect(wire.safetyMonitorName, model.safetyMonitorName);
      expect(wire.switchName, model.switchName);

      final back = EquipmentProfileModel.fromRemoteProfile(wire);
      expect(back.meridianFlipOverrides, model.meridianFlipOverrides);
      expect(back.safetyMonitorName, model.safetyMonitorName);
      expect(back.switchName, model.switchName);
    });

    test(
      'toRemoteProfile -> fromRemoteProfile preserves the full field set',
      () {
        final model = _sampleModel();
        final back = EquipmentProfileModel.fromRemoteProfile(
          model.toRemoteProfile(),
        );

        expect(back.id, model.id);
        expect(back.name, model.name);
        expect(back.description, model.description);
        expect(back.isActive, model.isActive);
        // Device ids.
        expect(back.cameraId, model.cameraId);
        expect(back.mountId, model.mountId);
        expect(back.focuserId, model.focuserId);
        expect(back.filterWheelId, model.filterWheelId);
        expect(back.guiderId, model.guiderId);
        expect(back.rotatorId, model.rotatorId);
        expect(back.domeId, model.domeId);
        expect(back.weatherId, model.weatherId);
        expect(back.safetyMonitorId, model.safetyMonitorId);
        expect(back.switchId, model.switchId);
        expect(back.coverCalibratorId, model.coverCalibratorId);
        // Friendly names.
        expect(back.cameraName, model.cameraName);
        expect(back.mountName, model.mountName);
        expect(back.focuserName, model.focuserName);
        expect(back.filterWheelName, model.filterWheelName);
        expect(back.guiderName, model.guiderName);
        expect(back.rotatorName, model.rotatorName);
        // Optical + camera defaults.
        expect(back.focalLength, model.focalLength);
        expect(back.aperture, model.aperture);
        expect(back.focalRatio, model.focalRatio);
        expect(back.defaultGain, model.defaultGain);
        expect(back.defaultOffset, model.defaultOffset);
        expect(back.defaultBinX, model.defaultBinX);
        expect(back.defaultBinY, model.defaultBinY);
        expect(back.defaultCoolingTemp, model.defaultCoolingTemp);
        expect(back.coolOnConnect, model.coolOnConnect);
        expect(back.defaultCenteringExposure, model.defaultCenteringExposure);
        // Filters / telescope / customization.
        expect(back.filterNames, model.filterNames);
        expect(back.filterFocusOffsets, model.filterFocusOffsets);
        expect(back.telescopeName, model.telescopeName);
        expect(back.telescopeFocalLength, model.telescopeFocalLength);
        expect(back.telescopeAperture, model.telescopeAperture);
        expect(back.profileIcon, model.profileIcon);
        expect(back.profileColor, model.profileColor);
        expect(back.sortOrder, model.sortOrder);
        expect(back.isDefault, model.isDefault);
      },
    );

    test('fromDatabase -> toRemoteProfile carries the override + name fields', () {
      // A host row read by the slave then re-emitted: the slave UI model is the
      // hop between the DB row and the wire, so its fromDatabase path must also
      // carry the three fields.
      final row = db.EquipmentProfile(
        id: 5,
        name: 'Host Rig',
        description: null,
        cameraId: null,
        mountId: null,
        focuserId: null,
        filterWheelId: null,
        guiderId: null,
        rotatorId: null,
        domeId: null,
        weatherId: null,
        safetyMonitorId: 'ascom:safety:0',
        switchId: 'ascom:switch:0',
        coverCalibratorId: null,
        focalLength: 0.0,
        aperture: 0.0,
        focalRatio: null,
        defaultGain: null,
        defaultOffset: null,
        defaultBinX: 1,
        defaultBinY: 1,
        defaultCoolingTemp: null,
        coolOnConnect: false,
        defaultCenteringExposure: null,
        filterNames: null,
        filterFocusOffsets: null,
        meridianFlipOverrides: '{"enabled":false}',
        cameraName: null,
        mountName: null,
        focuserName: null,
        filterWheelName: null,
        guiderName: null,
        rotatorName: null,
        safetyMonitorName: 'Roof Switch Safety',
        switchName: 'Mains',
        telescopeName: null,
        telescopeFocalLength: null,
        telescopeAperture: null,
        profileIcon: null,
        profileColor: null,
        sortOrder: 0,
        isDefault: false,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 6, 1),
        isActive: false,
      );

      final wire = EquipmentProfileModel.fromDatabase(row).toRemoteProfile();
      expect(wire.meridianFlipOverrides, '{"enabled":false}');
      expect(wire.safetyMonitorName, 'Roof Switch Safety');
      expect(wire.switchName, 'Mains');
    });

    test('a slave clearing meridian overrides emits null on the wire', () {
      // The explicit-clear case: the slave UI model has null overrides, so the
      // wire carries null. (The converter then preserves the host value via
      // its preserve-from-existing guard — locked in by the converter test —
      // so this null is a safe no-op rather than a wipe.)
      final cleared = _sampleModel(meridianFlipOverrides: null);
      final wire = cleared.toRemoteProfile();
      expect(wire.meridianFlipOverrides, isNull);

      final back = EquipmentProfileModel.fromRemoteProfile(wire);
      expect(back.meridianFlipOverrides, isNull);
    });

    test('round-trips through the wire JSON encoding losslessly', () {
      // Guards the freezed JSON codec for the three new fields end-to-end.
      final wire = _sampleModel().toRemoteProfile();
      final decoded = remote_profile.EquipmentProfile.fromJson(wire.toJson());
      expect(decoded.meridianFlipOverrides, wire.meridianFlipOverrides);
      expect(decoded.safetyMonitorName, wire.safetyMonitorName);
      expect(decoded.switchName, wire.switchName);
    });
  });
}
