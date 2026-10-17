import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/science_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'auto frame grading toggles the sequencer image grading default',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );

      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      await container.read(scienceSettingsProvider.future);
      await container
          .read(scienceSettingsProvider.notifier)
          .setAutoFrameGradingEnabled(true);

      final science = await container.read(scienceSettingsProvider.future);
      final appSettings = await container.read(appSettingsProvider.future);

      expect(science.autoFrameGradingEnabled, isTrue);
      expect(appSettings.enableImageGrading, isTrue);
      expect(
        await db.settingsDao.getSetting('science.grading.auto_enabled'),
        'true',
      );
      expect(await db.settingsDao.getSetting('image_grading_enabled'), 'true');
    },
  );

  test(
    'science settings reflect an existing sequencer image grading default',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      await db.settingsDao.setSetting('image_grading_enabled', 'true');
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );

      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      final science = await container.read(scienceSettingsProvider.future);

      expect(science.autoFrameGradingEnabled, isTrue);
    },
  );
}
