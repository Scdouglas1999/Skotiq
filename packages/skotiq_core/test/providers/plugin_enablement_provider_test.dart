// Tests for plugin enablement persistence.
//
// Uses a real in-memory SkotiqDatabase (and therefore a real SettingsDao)
// rather than a hand-rolled fake, so the round-trip exercises the actual
// `app_settings` upsert path the production code uses. The single C3 dependency
// — the canonical plugin id list — is overridden via [managedPluginIdsProvider]
// with a fixed id set so the tests don't depend on which example plugins ship.

import 'dart:convert';

import 'package:drift/drift.dart' show InsertMode;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

const _pluginA = 'com.test.plugin_a';
const _pluginB = 'com.test.plugin_b';
const _pluginC = 'com.test.plugin_c';
const _allIds = [_pluginA, _pluginB, _pluginC];

class _ControllableSettingsDao extends SettingsDao {
  _ControllableSettingsDao(super.db);

  bool failWrites = false;

  @override
  Future<void> setSetting(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    await super.setSetting(key, value);
  }
}

Future<String?> _readSetting(SkotiqDatabase db) {
  return SettingsDao(db).getSetting(kPluginEnablementSettingKey);
}

Future<void> _seedSetting(SkotiqDatabase db, String value) async {
  await db
      .into(db.appSettings)
      .insert(
        AppSettingsCompanion.insert(
          key: kPluginEnablementSettingKey,
          value: value,
        ),
        mode: InsertMode.insertOrReplace,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pluginEnablementProvider', () {
    late ProviderContainer container;
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          managedPluginIdsProvider.overrideWithValue(_allIds),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('absent id (and empty store) reads as enabled by default', () async {
      final enabled = await container.read(pluginEnablementProvider.future);

      // Nothing persisted yet → every managed plugin is enabled.
      expect(enabled, unorderedEquals(_allIds));

      final notifier = container.read(pluginEnablementProvider.notifier);
      expect(notifier.isEnabled(_pluginA), isTrue);
      expect(notifier.isEnabled(_pluginB), isTrue);
      expect(notifier.isEnabled(_pluginC), isTrue);

      // No write should have happened just from reading defaults.
      expect(await _readSetting(database), isNull);
    });

    test('id explicitly enabled in the store reads as enabled', () async {
      await _seedSetting(database, jsonEncode({_pluginA: true}));

      final enabled = await container.read(pluginEnablementProvider.future);
      expect(enabled, unorderedEquals(_allIds));
    });

    test('setEnabled(id, false) persists and is observed', () async {
      await container.read(pluginEnablementProvider.future);
      final notifier = container.read(pluginEnablementProvider.notifier);

      await notifier.setEnabled(_pluginB, false);

      // Live state reflects the change immediately.
      final state = container.read(pluginEnablementProvider).requireValue;
      expect(state, unorderedEquals([_pluginA, _pluginC]));
      expect(notifier.isEnabled(_pluginB), isFalse);
      expect(notifier.isEnabled(_pluginA), isTrue);

      // Persisted JSON records exactly the explicit choice.
      final raw = await _readSetting(database);
      expect(raw, isNotNull);
      expect(jsonDecode(raw!), {_pluginB: false});
    });

    test('disabled choice round-trips through a fresh provider read', () async {
      await container.read(pluginEnablementProvider.future);
      await container
          .read(pluginEnablementProvider.notifier)
          .setEnabled(_pluginA, false);

      // Re-read from a brand-new container backed by the same database to
      // prove the choice was persisted (not just held in memory).
      final reopened = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          managedPluginIdsProvider.overrideWithValue(_allIds),
        ],
      );
      addTearDown(reopened.dispose);

      final enabled = await reopened.read(pluginEnablementProvider.future);
      expect(enabled, unorderedEquals([_pluginB, _pluginC]));
    });

    test('re-enabling a previously disabled id round-trips', () async {
      await container.read(pluginEnablementProvider.future);
      final notifier = container.read(pluginEnablementProvider.notifier);

      await notifier.setEnabled(_pluginA, false);
      await notifier.setEnabled(_pluginA, true);

      expect(
        container.read(pluginEnablementProvider).requireValue,
        unorderedEquals(_allIds),
      );
      expect(jsonDecode((await _readSetting(database))!), {_pluginA: true});
    });

    test(
      'stale persisted id outside the managed set never leaks into the set',
      () async {
        // A plugin that was removed from the build but still has a persisted
        // choice must not appear in the live enabled set.
        await _seedSetting(
          database,
          jsonEncode({'com.test.removed_plugin': true, _pluginB: false}),
        );

        final enabled = await container.read(pluginEnablementProvider.future);
        expect(enabled, unorderedEquals([_pluginA, _pluginC]));
      },
    );

    test(
      'malformed JSON fails closed to all-enabled with a surfaced log',
      () async {
        await _seedSetting(database, '{ this is not json');

        final records = <LogRecord>[];
        final sub = Logger(
          'PluginEnablementProvider',
        ).onRecord.listen(records.add);
        addTearDown(sub.cancel);

        final enabled = await container.read(pluginEnablementProvider.future);

        // Fail closed to the safe fresh-install state: everything enabled.
        expect(enabled, unorderedEquals(_allIds));

        // The corruption was surfaced, not silently swallowed.
        expect(
          records.where((r) => r.level >= Level.WARNING),
          isNotEmpty,
          reason: 'malformed plugin_enablement JSON must be logged',
        );
        expect(
          records.any((r) => r.message.contains('Malformed plugin_enablement')),
          isTrue,
        );
      },
    );

    test('malformed individual entries are skipped and logged', () async {
      // Valid JSON object, but with a non-bool value and a non-string key shape
      // (numeric key serialises as a string by JSON, so use a non-bool value).
      await _seedSetting(
        database,
        jsonEncode({_pluginA: 'yes', _pluginB: false}),
      );

      final records = <LogRecord>[];
      final sub = Logger(
        'PluginEnablementProvider',
      ).onRecord.listen(records.add);
      addTearDown(sub.cancel);

      final enabled = await container.read(pluginEnablementProvider.future);

      // _pluginA's bad entry is ignored → defaults to enabled; _pluginB stays
      // disabled per its valid entry; _pluginC defaults to enabled.
      expect(enabled, unorderedEquals([_pluginA, _pluginC]));
      expect(
        records.any(
          (r) =>
              r.level >= Level.WARNING &&
              r.message.contains('malformed plugin_enablement entry'),
        ),
        isTrue,
      );
    });
  });

  group('SettingsPluginEnablementStore', () {
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('absent id reports enabled by default', () async {
      final store = SettingsPluginEnablementStore(SettingsDao(database));
      expect(await store.isEnabled(_pluginA), isTrue);
    });

    test('reflects an explicitly disabled persisted choice', () async {
      await _seedSetting(database, jsonEncode({_pluginA: false}));
      final store = SettingsPluginEnablementStore(SettingsDao(database));

      expect(await store.isEnabled(_pluginA), isFalse);
      expect(await store.isEnabled(_pluginB), isTrue);
    });

    test('store and notifier agree after a setEnabled write', () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          managedPluginIdsProvider.overrideWithValue(_allIds),
        ],
      );
      addTearDown(container.dispose);

      await container.read(pluginEnablementProvider.future);
      await container
          .read(pluginEnablementProvider.notifier)
          .setEnabled(_pluginC, false);

      final store = container.read(settingsPluginEnablementStoreProvider);
      expect(await store.isEnabled(_pluginC), isFalse);
      expect(await store.isEnabled(_pluginA), isTrue);
    });

    test('fails closed to enabled on malformed JSON', () async {
      await _seedSetting(database, 'not-json-at-all');
      final store = SettingsPluginEnablementStore(SettingsDao(database));

      expect(await store.isEnabled(_pluginA), isTrue);
    });
  });

  // Verifies the headline behaviour the review flagged: toggling enablement
  // must drive the LIVE PluginHost (run onEnable/onDisable), not merely persist
  // a bit. Uses a real PluginHost with a real plugin so the lifecycle callbacks
  // actually fire.
  group('setEnabled drives the live PluginHost', () {
    late ProviderContainer container;
    late SkotiqDatabase database;
    late PluginHost host;
    late _LifecyclePlugin plugin;
    late _ControllableSettingsDao settingsDao;

    setUp(() async {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      host = PluginHost();
      settingsDao = _ControllableSettingsDao(database);
      plugin = _LifecyclePlugin(_pluginA);
      // Register enabled so the starting state is "on" — disabling must then
      // run onDisable exactly once. registerPlugin runs onEnable once for an
      // enabled plugin, so zero the counters AFTER registration: each test then
      // measures only the toggle-driven lifecycle transitions.
      await host.registerPlugin(plugin, enabled: true);
      plugin.enableCount = 0;
      plugin.disableCount = 0;

      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(settingsDao),
          managedPluginIdsProvider.overrideWithValue(_allIds),
          pluginHostProvider.overrideWithValue(host),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await host.dispose();
      await database.close();
    });

    test('disabling runs onDisable and flips host enabled state', () async {
      await container.read(pluginEnablementProvider.future);
      expect(host.isEnabled(_pluginA), isTrue);
      expect(plugin.disableCount, 0);

      await container
          .read(pluginEnablementProvider.notifier)
          .setEnabled(_pluginA, false);

      // Live host transitioned.
      expect(host.isEnabled(_pluginA), isFalse);
      expect(plugin.disableCount, 1);
      expect(plugin.enableCount, 0);

      // Persisted + live set reflect the choice too.
      expect(jsonDecode((await _readSetting(database))!), {_pluginA: false});
      expect(
        container.read(pluginEnablementProvider).requireValue,
        isNot(contains(_pluginA)),
      );
    });

    test('re-enabling runs onEnable and flips host state back', () async {
      await container.read(pluginEnablementProvider.future);
      final notifier = container.read(pluginEnablementProvider.notifier);

      await notifier.setEnabled(_pluginA, false);
      await notifier.setEnabled(_pluginA, true);

      expect(host.isEnabled(_pluginA), isTrue);
      expect(plugin.disableCount, 1);
      expect(plugin.enableCount, 1);
      expect(jsonDecode((await _readSetting(database))!), {_pluginA: true});
    });

    test('an unloaded id is persisted without touching the host', () async {
      await container.read(pluginEnablementProvider.future);

      // _pluginB is managed but NOT loaded in the host — setEnabled must not
      // throw and must still persist the choice.
      await container
          .read(pluginEnablementProvider.notifier)
          .setEnabled(_pluginB, false);

      expect(host.isLoaded(_pluginB), isFalse);
      expect(jsonDecode((await _readSetting(database))!), {_pluginB: false});
      // The loaded plugin's lifecycle was untouched.
      expect(plugin.enableCount, 0);
      expect(plugin.disableCount, 0);
    });

    test('parallel toggles preserve both persisted choices', () async {
      await container.read(pluginEnablementProvider.future);
      final notifier = container.read(pluginEnablementProvider.notifier);

      await Future.wait([
        notifier.setEnabled(_pluginA, false),
        notifier.setEnabled(_pluginB, false),
      ]);

      expect(jsonDecode((await _readSetting(database))!), {
        _pluginA: false,
        _pluginB: false,
      });
      expect(
        container.read(pluginEnablementProvider).requireValue,
        unorderedEquals([_pluginC]),
      );
    });

    test(
      'failed persistence rolls the live host back to its prior state',
      () async {
        await container.read(pluginEnablementProvider.future);
        settingsDao.failWrites = true;

        await expectLater(
          container
              .read(pluginEnablementProvider.notifier)
              .setEnabled(_pluginA, false),
          throwsStateError,
        );

        expect(host.isEnabled(_pluginA), isTrue);
        expect(plugin.disableCount, 1);
        expect(plugin.enableCount, 1);
        expect(await _readSetting(database), isNull);
        expect(
          container.read(pluginEnablementProvider).requireValue,
          contains(_pluginA),
        );
      },
    );
  });
}

/// Minimal plugin that counts its enable/disable lifecycle invocations so the
/// test can assert `setEnabled` actually drove the host.
class _LifecyclePlugin extends SkotiqPlugin {
  _LifecyclePlugin(this.id);

  @override
  final String id;

  int enableCount = 0;
  int disableCount = 0;

  @override
  String get name => 'Lifecycle Test Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Counts onEnable/onDisable for tests.';

  @override
  String get author => 'Skotiq Tests';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onEnable() async {
    enableCount++;
  }

  @override
  Future<void> onDisable() async {
    disableCount++;
  }

  @override
  Future<void> onUnload() async {}
}
