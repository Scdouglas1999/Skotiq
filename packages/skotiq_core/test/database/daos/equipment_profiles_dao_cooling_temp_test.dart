import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/equipment_profiles_dao.dart';

/// Covers [EquipmentProfilesDao.setActiveProfileDefaultCoolingTemp] — the
/// write path the Quick-Start wizard uses to persist the chosen cooling
/// temperature onto whichever profile is currently active.
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

  test('writes the cooling temp onto the active profile only', () async {
    // First profile becomes default + active; second is inactive.
    final activeId = await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Active rig'),
    );
    final otherId = await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Spare rig'),
    );

    final rows = await dao.setActiveProfileDefaultCoolingTemp(-10.0);
    expect(rows, 1);

    final active = await dao.getProfileById(activeId);
    final other = await dao.getProfileById(otherId);
    expect(active!.defaultCoolingTemp, -10.0);
    // The inactive profile is untouched.
    expect(other!.defaultCoolingTemp, isNull);
  });

  test('passing null clears the active profile cooling temp', () async {
    final id = await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Rig'),
    );
    await dao.setActiveProfileDefaultCoolingTemp(-15.0);
    expect((await dao.getProfileById(id))!.defaultCoolingTemp, -15.0);

    await dao.setActiveProfileDefaultCoolingTemp(null);
    expect((await dao.getProfileById(id))!.defaultCoolingTemp, isNull);
  });

  test('returns 0 when there is no active profile', () async {
    final rows = await dao.setActiveProfileDefaultCoolingTemp(-5.0);
    expect(rows, 0);
  });
}
