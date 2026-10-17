import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/tutorial_provider.dart';

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('tutorial enablement survives provider recreation', () async {
    final first = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    await first.read(tutorialProvider.notifier).setTutorialsEnabled(false);
    first.dispose();

    final second = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(second.dispose);
    second.read(tutorialProvider);
    await pumpEventQueue();

    expect(second.read(tutorialProvider).tutorialsEnabled, isFalse);
  });

  test(
    'failed enablement persistence leaves confirmed state unchanged',
    () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(_FailingSettingsDao(database)),
        ],
      );
      addTearDown(container.dispose);
      container.read(tutorialProvider);
      await pumpEventQueue();

      await expectLater(
        container.read(tutorialProvider.notifier).setTutorialsEnabled(false),
        throwsStateError,
      );

      expect(container.read(tutorialProvider).tutorialsEnabled, isTrue);
    },
  );

  test('resetting progress does not silently re-enable tutorials', () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(tutorialProvider.notifier);
    await notifier.setTutorialsEnabled(false);

    await notifier.resetProgress();

    expect(container.read(tutorialProvider).tutorialsEnabled, isFalse);
  });

  test('rapid enablement changes persist in invocation order', () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(tutorialProvider.notifier);

    await Future.wait([
      notifier.setTutorialsEnabled(false),
      notifier.setTutorialsEnabled(true),
    ]);

    expect(container.read(tutorialProvider).tutorialsEnabled, isTrue);
    expect(await database.settingsDao.getSetting('tutorials_enabled'), 'true');
  });
}
