import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';

void main() {
  late SkotiqDatabase database;
  late SettingsDao dao;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = SettingsDao(database);
  });

  tearDown(() => database.close());

  test(
    'canonical image path reads legacy non-empty value during migration',
    () async {
      await dao.setSetting('image_output_path', '');
      await dao.setSetting('default_image_directory', '/legacy/captures');

      expect(await dao.getImageOutputDirectory(), '/legacy/captures');
    },
  );

  test(
    'setting image output path keeps both database keys synchronized',
    () async {
      await dao.setImageOutputDirectory('/new/captures');

      expect(await dao.getSetting('image_output_path'), '/new/captures');
      expect(await dao.getSetting('default_image_directory'), '/new/captures');
    },
  );
}
