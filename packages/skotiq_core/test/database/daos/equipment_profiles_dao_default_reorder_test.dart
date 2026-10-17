// The atomic primitives the dedicated remote set-default / clear-default /
// reorder endpoints route through. These are the ONLY thing that lets a slave
// mutate the host's `isDefault` / `sortOrder` (the
// generic `remoteProfileToDbRow` save path deliberately preserves both). The
// handler-level wiring is covered in apps/desktop; this isolates the DAO so the
// atomic unset-others-then-set + reorder-by-index behavior is independently
// verifiable against a real in-memory Drift DB.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EquipmentProfilesDao default + reorder primitives', () {
    late SkotiqDatabase db;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    Future<int> seed(String name, {int sortOrder = 0}) {
      return db.equipmentProfilesDao.createProfile(
        EquipmentProfilesCompanion.insert(
          name: name,
          sortOrder: Value(sortOrder),
        ),
      );
    }

    test('setDefaultProfile unsets every other row and moves active', () async {
      final idA = await seed('A', sortOrder: 0);
      final idB = await seed('B', sortOrder: 1);
      final idC = await seed('C', sortOrder: 2);

      // The first-created profile is the initial default + active.
      expect((await db.equipmentProfilesDao.getDefaultProfile())?.id, idA);
      expect((await db.equipmentProfilesDao.getActiveProfile())?.id, idA);

      await db.equipmentProfilesDao.setDefaultProfile(idB);

      final rows = await db.equipmentProfilesDao.getAllProfiles();
      final byId = {for (final r in rows) r.id: r};
      // Exactly one default, on the target.
      expect(rows.where((r) => r.isDefault).map((r) => r.id), [idB]);
      expect(byId[idA]!.isDefault, isFalse);
      expect(byId[idC]!.isDefault, isFalse);
      // makeActive defaults true -> active follows the new default.
      expect((await db.equipmentProfilesDao.getActiveProfile())?.id, idB);
    });

    test('setDefaultProfile makeActive:false leaves active alone', () async {
      final idA = await seed('A');
      final idB = await seed('B');
      expect((await db.equipmentProfilesDao.getActiveProfile())?.id, idA);

      await db.equipmentProfilesDao.setDefaultProfile(idB, makeActive: false);

      expect((await db.equipmentProfilesDao.getDefaultProfile())?.id, idB);
      // Active selection unchanged.
      expect((await db.equipmentProfilesDao.getActiveProfile())?.id, idA);
    });

    test(
      'clearDefaultProfile unsets default without touching active',
      () async {
        final idA = await seed('A');
        expect((await db.equipmentProfilesDao.getDefaultProfile())?.id, idA);

        await db.equipmentProfilesDao.clearDefaultProfile();

        expect(await db.equipmentProfilesDao.getDefaultProfile(), isNull);
        expect((await db.equipmentProfilesDao.getActiveProfile())?.id, idA);
      },
    );

    test('reorderProfiles assigns sortOrder == posted index', () async {
      final idA = await seed('A', sortOrder: 0);
      final idB = await seed('B', sortOrder: 1);
      final idC = await seed('C', sortOrder: 2);

      // Reverse the order.
      await db.equipmentProfilesDao.reorderProfiles([idC, idB, idA]);

      final byId = {
        for (final r in await db.equipmentProfilesDao.getAllProfiles()) r.id: r,
      };
      expect(byId[idC]!.sortOrder, 0);
      expect(byId[idB]!.sortOrder, 1);
      expect(byId[idA]!.sortOrder, 2);
    });

    test('reorderProfiles skips ids that no longer resolve', () async {
      final idA = await seed('A', sortOrder: 0);
      final idB = await seed('B', sortOrder: 1);

      // 999999 is stale/deleted; it must not fail the whole reorder.
      await db.equipmentProfilesDao.reorderProfiles([idB, 999999, idA]);

      final byId = {
        for (final r in await db.equipmentProfilesDao.getAllProfiles()) r.id: r,
      };
      expect(byId[idB]!.sortOrder, 0);
      expect(byId[idA]!.sortOrder, 2);
    });

    test('reorderProfiles leaves other columns untouched', () async {
      final idA = await seed('A', sortOrder: 0);
      final idB = await seed('B', sortOrder: 1);
      // A is the default (first created); reorder must not change that.
      expect((await db.equipmentProfilesDao.getDefaultProfile())?.id, idA);

      await db.equipmentProfilesDao.reorderProfiles([idB, idA]);

      expect((await db.equipmentProfilesDao.getDefaultProfile())?.id, idA);
      expect((await db.equipmentProfilesDao.getActiveProfile())?.id, idA);
    });
  });
}
