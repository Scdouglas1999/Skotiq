// End-to-end wiring test for C3 (registration) + C4 (settings-backed
// enablement persistence).
//
// This crosses the exact seam the app entry points wire in production:
//
//   pluginEnablementStoreProvider  (C3, skotiq_plugins)
//       └─ overridden with ─▶ settingsPluginEnablementStoreProvider (C4, core)
//                                  └─ reads the persisted `plugin_enablement`
//                                     map from a real SettingsDao / Drift DB.
//
// It proves the behaviour the review flagged as a blocker: with a persisted
// `{discord:false}` choice and the override installed (the same one
// `pluginEnablementStoreOverride()` builds), `pluginRegistrationProvider`
// registers the Discord plugin LOADED but NOT enabled — i.e. the user's saved
// disable choice survives a fresh launch instead of being silently re-enabled.

import 'dart:convert';

import 'package:drift/drift.dart' show InsertMode;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import 'package:skotiq_plugins/src/plugin_registration.dart';

const _discordId = 'com.skotiq.examples.discord_webhook';
const _pushoverId = 'com.skotiq.examples.pushover';

Future<void> _seedEnablement(
  SkotiqDatabase db,
  Map<String, bool> choices,
) async {
  await db
      .into(db.appSettings)
      .insert(
        AppSettingsCompanion.insert(
          key: kPluginEnablementSettingKey,
          value: jsonEncode(choices),
        ),
        mode: InsertMode.insertOrReplace,
      );
}

/// Mirrors the production composition root: override C3's
/// `pluginEnablementStoreProvider` with C4's settings-backed store. (The app
/// installs this via `pluginEnablementStoreOverride()` in `skotiq_app`;
/// `skotiq_core` can't import that helper, so we inline the identical
/// override here.)
Override _settingsBackedEnablementOverride() {
  return pluginEnablementStoreProvider.overrideWith(
    (ref) => ref.watch(settingsPluginEnablementStoreProvider),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings-backed enablement honoured at registration', () {
    late SkotiqDatabase database;
    late PluginHost host;
    late ProviderContainer container;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      host = PluginHost();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          pluginHostProvider.overrideWithValue(host),
          _settingsBackedEnablementOverride(),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await host.dispose();
      await database.close();
    });

    test(
      'persisted {discord:false} registers Discord loaded-but-disabled',
      () async {
        await _seedEnablement(database, {_discordId: false});

        await container.read(pluginRegistrationProvider.future);

        // Loaded (so it appears in the Integrations list + can be re-enabled)…
        expect(host.isLoaded(_discordId), isTrue);
        // …but NOT enabled: the user's saved disable choice was honoured.
        expect(host.isEnabled(_discordId), isFalse);

        // Every other bundled plugin defaults to enabled.
        expect(host.isEnabled(_pushoverId), isTrue);
        expect(host.isEnabled('com.skotiq.examples.home_assistant'), isTrue);
        expect(host.isEnabled('com.skotiq.weatherlogger'), isTrue);
      },
    );

    test('no persisted choice registers every plugin enabled', () async {
      // Nothing seeded → fresh-install default: all on.
      await container.read(pluginRegistrationProvider.future);

      for (final descriptor in kUserFacingExamplePlugins) {
        expect(host.isLoaded(descriptor.id), isTrue, reason: descriptor.id);
        expect(host.isEnabled(descriptor.id), isTrue, reason: descriptor.id);
      }
    });

    test('a toggle then re-registration round-trips through the DB', () async {
      // Start all-enabled.
      await container.read(pluginRegistrationProvider.future);
      expect(host.isEnabled(_discordId), isTrue);

      // User disables Discord on the Integrations page (drives host + persists).
      await container
          .read(pluginEnablementProvider.notifier)
          .setEnabled(_discordId, false);
      expect(host.isEnabled(_discordId), isFalse);

      // Simulate a relaunch: brand-new host + container over the SAME database.
      final host2 = PluginHost();
      final container2 = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          pluginHostProvider.overrideWithValue(host2),
          _settingsBackedEnablementOverride(),
        ],
      );
      addTearDown(() async {
        container2.dispose();
        await host2.dispose();
      });

      await container2.read(pluginRegistrationProvider.future);

      // The disable choice survived the relaunch.
      expect(host2.isLoaded(_discordId), isTrue);
      expect(host2.isEnabled(_discordId), isFalse);
    });
  });
}
