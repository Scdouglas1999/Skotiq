import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/equipment_profiles_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

/// Covers [EquipmentProfilesDao.duplicateProfile] — the "Copy profile" path.
///
/// A copied profile is what startup auto-connect later drives, so it must carry
/// EVERY configured device slot forward. A copy that drops `switchId` (or the
/// `switchName` / `safetyMonitorName` friendly labels) turns a rig with a
/// power/switch box into a profile auto-connect never attempts the switch for.
/// A copy must also never inherit the source's active/default flags (no stale
/// mutation).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late EquipmentProfilesDao dao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = EquipmentProfilesDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'copies EVERY relevant profile field (not just the recently-noticed slots)',
    () async {
      // Populate every column that a copy must carry forward. If a future edit
      // adds a column to the table + companion but forgets it in
      // duplicateProfile, extend this list so the gap is caught here.
      final sourceId = await dao.createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Observatory rig',
          description: const Value('main imaging scope'),
          // Device identifiers.
          cameraId: const Value('ascom:camera:1'),
          mountId: const Value('ascom:mount:1'),
          focuserId: const Value('ascom:focuser:1'),
          filterWheelId: const Value('ascom:fw:1'),
          guiderId: const Value('phd2:guider:1'),
          rotatorId: const Value('ascom:rotator:1'),
          domeId: const Value('ascom:dome:1'),
          weatherId: const Value('ascom:weather:1'),
          safetyMonitorId: const Value('ascom:safety:1'),
          switchId: const Value('ascom:switch:1'),
          coverCalibratorId: const Value('ascom:flat:1'),
          // Friendly device names.
          cameraName: const Value('ASI2600'),
          mountName: const Value('AM5'),
          focuserName: const Value('EAF'),
          filterWheelName: const Value('EFW'),
          guiderName: const Value('OAG'),
          rotatorName: const Value('Falcon'),
          safetyMonitorName: const Value('CloudWatcher'),
          switchName: const Value('Pegasus UPB'),
          // Optics.
          focalLength: const Value(530.0),
          aperture: const Value(106.0),
          focalRatio: const Value(5.0),
          telescopeName: const Value('Redcat 51'),
          telescopeFocalLength: const Value(250.0),
          telescopeAperture: const Value(51.0),
          // Camera defaults.
          defaultGain: const Value(100),
          defaultOffset: const Value(30),
          defaultBinX: const Value(2),
          defaultBinY: const Value(2),
          defaultCoolingTemp: const Value(-10.0),
          coolOnConnect: const Value(true),
          defaultCenteringExposure: const Value(3.5),
          // Filters + meridian-flip overrides (JSON blobs).
          filterNames: const Value('["L","R","G","B"]'),
          filterFocusOffsets: const Value('{"L":0,"R":10}'),
          meridianFlipOverrides: const Value('{"minutesAfter":5}'),
          // Customization.
          profileIcon: const Value('telescope'),
          profileColor: const Value(0xFF2196F3),
          sortOrder: const Value(7),
        ),
      );

      final copyId = await dao.duplicateProfile(
        sourceId,
        'Observatory rig (copy)',
      );
      final copy = (await dao.getProfileById(copyId))!;

      // New identity + new name.
      expect(copyId, isNot(sourceId));
      expect(copy.name, 'Observatory rig (copy)');

      // Device identifiers.
      expect(copy.description, 'main imaging scope');
      expect(copy.cameraId, 'ascom:camera:1');
      expect(copy.mountId, 'ascom:mount:1');
      expect(copy.focuserId, 'ascom:focuser:1');
      expect(copy.filterWheelId, 'ascom:fw:1');
      expect(copy.guiderId, 'phd2:guider:1');
      expect(copy.rotatorId, 'ascom:rotator:1');
      expect(copy.domeId, 'ascom:dome:1');
      expect(copy.weatherId, 'ascom:weather:1');
      expect(copy.safetyMonitorId, 'ascom:safety:1');
      expect(copy.switchId, 'ascom:switch:1');
      expect(copy.coverCalibratorId, 'ascom:flat:1');
      // Friendly names.
      expect(copy.cameraName, 'ASI2600');
      expect(copy.mountName, 'AM5');
      expect(copy.focuserName, 'EAF');
      expect(copy.filterWheelName, 'EFW');
      expect(copy.guiderName, 'OAG');
      expect(copy.rotatorName, 'Falcon');
      expect(copy.safetyMonitorName, 'CloudWatcher');
      expect(copy.switchName, 'Pegasus UPB');
      // Optics.
      expect(copy.focalLength, 530.0);
      expect(copy.aperture, 106.0);
      expect(copy.focalRatio, 5.0);
      expect(copy.telescopeName, 'Redcat 51');
      expect(copy.telescopeFocalLength, 250.0);
      expect(copy.telescopeAperture, 51.0);
      // Camera defaults.
      expect(copy.defaultGain, 100);
      expect(copy.defaultOffset, 30);
      expect(copy.defaultBinX, 2);
      expect(copy.defaultBinY, 2);
      expect(copy.defaultCoolingTemp, -10.0);
      expect(copy.coolOnConnect, isTrue);
      expect(copy.defaultCenteringExposure, 3.5);
      // Filters + meridian flip.
      expect(copy.filterNames, '["L","R","G","B"]');
      expect(copy.filterFocusOffsets, '{"L":0,"R":10}');
      expect(copy.meridianFlipOverrides, '{"minutesAfter":5}');
      // Customization.
      expect(copy.profileIcon, 'telescope');
      expect(copy.profileColor, 0xFF2196F3);
      expect(copy.sortOrder, 7);

      // ...but NEVER the active/default flags (a copy is inert).
      expect(copy.isActive, isFalse);
      expect(copy.isDefault, isFalse);
    },
  );

  test('the copy never inherits active/default flags', () async {
    // The first profile auto-becomes default + active.
    final sourceId = await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Primary'),
    );
    final source = (await dao.getProfileById(sourceId))!;
    expect(source.isActive, isTrue);
    expect(source.isDefault, isTrue);

    final copyId = await dao.duplicateProfile(sourceId, 'Primary (copy)');
    final copy = (await dao.getProfileById(copyId))!;

    // No stale mutation: a copy is inert until the user activates it.
    expect(copy.isActive, isFalse);
    expect(copy.isDefault, isFalse);
    // ...and the source's active/default status is untouched.
    final sourceAfter = (await dao.getProfileById(sourceId))!;
    expect(sourceAfter.isActive, isTrue);
    expect(sourceAfter.isDefault, isTrue);
  });
}
