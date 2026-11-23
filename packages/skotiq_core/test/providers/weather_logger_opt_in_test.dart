// The Weather Logger records weather into plugin storage all night; like the
// other background data builders it is opt-in. An install that never chose
// keeps it off, a stored choice either way is kept, and the other bundled
// plugins still start on.
import 'dart:convert';

import 'package:drift/drift.dart' show InsertMode;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart';

const _weatherLogger = 'com.skotiq.weatherlogger';
const _discord = 'com.skotiq.examples.discord_webhook';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({Set<String> live, bool store})> resolve(String? stored) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    if (stored != null) {
      await db
          .into(db.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: 'plugin_enablement',
              value: stored,
            ),
            mode: InsertMode.insertOrReplace,
          );
    }
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final live = await container.read(pluginEnablementProvider.future);
    final store = await SettingsPluginEnablementStore(
      SettingsDao(db),
    ).isEnabled(_weatherLogger);
    return (live: live, store: store);
  }

  test('no stored choice: the Weather Logger starts off, others on', () async {
    final r = await resolve(null);
    expect(r.live, isNot(contains(_weatherLogger)));
    expect(r.live, contains(_discord));
    expect(r.store, isFalse);
  });

  test('a stored "on" is kept', () async {
    final r = await resolve(jsonEncode({_weatherLogger: true}));
    expect(r.live, contains(_weatherLogger));
    expect(r.store, isTrue);
  });

  test('a stored "off" is kept', () async {
    final r = await resolve(jsonEncode({_weatherLogger: false}));
    expect(r.live, isNot(contains(_weatherLogger)));
    expect(r.store, isFalse);
  });
}
