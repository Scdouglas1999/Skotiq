import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FailingReadSettingsDao extends SettingsDao {
  _FailingReadSettingsDao(super.db);

  int writes = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (key == 'session_insights.dismissed') {
      throw StateError('dismissal database unavailable');
    }
    return super.getSetting(key);
  }

  @override
  Future<void> setSetting(String key, String value) async {
    writes++;
    await super.setSetting(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('load failure refuses empty-set dismissal overwrite', () async {
    final dao = _FailingReadSettingsDao(database);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(dao),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(dismissedSessionInsightsProvider.future),
      throwsStateError,
    );
    await expectLater(
      container
          .read(dismissedSessionInsightsProvider.notifier)
          .dismiss('guiding'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('refusing to overwrite them with an empty set'),
        ),
      ),
    );
    expect(dao.writes, 0);
  });

  test('rapid dismissals preserve every insight id', () async {
    await database.settingsDao.setSetting(
      'session_insights.dismissed',
      'existing',
    );
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    await container.read(dismissedSessionInsightsProvider.future);
    final notifier = container.read(dismissedSessionInsightsProvider.notifier);

    await Future.wait([
      notifier.dismiss('guiding'),
      notifier.dismiss('autofocus'),
    ]);

    expect(container.read(dismissedSessionInsightsProvider).requireValue, {
      'existing',
      'guiding',
      'autofocus',
    });
    final stored = await database.settingsDao.getSetting(
      'session_insights.dismissed',
    );
    expect(stored!.split(',').toSet(), {'existing', 'guiding', 'autofocus'});
  });
}
