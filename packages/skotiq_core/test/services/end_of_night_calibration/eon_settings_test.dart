import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  test(
    'library darks stay valid 120 days until the operator says otherwise',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = SettingsDao(db);

      expect((await EonSettings.load(dao)).darkValidDays, 120);
      await dao.setSettings(
        (await EonSettings.load(dao)).copyWith(darkValidDays: 30).toStorage(),
      );
      expect((await EonSettings.load(dao)).darkValidDays, 30);
      await dao.setSetting(EonSettings.darkValidDaysKey, '0');
      expect((await EonSettings.load(dao)).darkValidDays, 1);
    },
  );
}
