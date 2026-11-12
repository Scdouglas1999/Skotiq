// GET/POST /api/settings/store: the host's key/value settings rows a linked
// client mirrors.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/handlers/profile_handlers.dart';
import 'package:skotiq_desktop/headless_api/request_context.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockProfileSettingsBackend extends Mock
    implements ProfileSettingsBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late SkotiqDatabase db;
  late ProfileHandlers handlers;
  late List<SkotiqEvent> announced;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final profileBackend = _MockProfileSettingsBackend();
    when(() => profileBackend.getLocation()).thenAnswer((_) async => null);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
        profileSettingsBackendProvider.overrideWithValue(profileBackend),
      ],
    );
    announced = [];
    container.read(hostMutationEventHubProvider).wsBroadcast = announced.add;
    handlers = ProfileHandlers(container);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Map<String, Object> grantOf(HeadlessTokenScope scope) => {
    authGrantContextKey: HeadlessAuthGrant.fromCoarse(scope),
  };

  Future<Response> post(
    Map<String, Object?> body, {
    HeadlessTokenScope scope = HeadlessTokenScope.control,
  }) => translateHandlerErrors(
    handlers.handleUpdateSettingsStore(
      Request(
        'POST',
        Uri.parse('http://localhost/api/settings/store'),
        body: jsonEncode(body),
        context: grantOf(scope),
      ),
    ),
  );

  Future<Map<String, dynamic>> getStoreBody({
    HeadlessTokenScope scope = HeadlessTokenScope.control,
  }) async {
    final response = await handlers.handleGetSettingsStore(
      Request(
        'GET',
        Uri.parse('http://localhost/api/settings/store'),
        context: grantOf(scope),
      ),
    );
    expect(response.statusCode, HttpStatus.ok);
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getStore() async =>
      ((await getStoreBody())['settings'] as Map).cast<String, dynamic>();

  test('serves host-owned rows and keeps this screen\'s preferences', () async {
    await db.settingsDao.setSettings({
      'sequencer_dither_pixels': '4.5',
      'camera_presets': '[]',
      'sequencer_density_v1': 'compact',
      'constellation.hub_token': 'secret',
    });
    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setMountSiteSyncMode('never');

    final store = await getStore();

    expect(store['sequencer_dither_pixels'], '4.5');
    expect(store['camera_presets'], '[]');
    expect(store['mount_site_sync_mode'], 'never');
    expect(store.containsKey('sequencer_density_v1'), isFalse);
    expect(store.containsKey('constellation.hub_token'), isFalse);
  });

  test(
    'a write lands in the database, reloads readers and is announced',
    () async {
      await container.read(appSettingsProvider.future);
      final revision = container.read(settingsStoreRevisionProvider);

      final response = await post({
        'settings': {'sequencer_dither_pixels': 2.5, 'scheduler_config': '{}'},
      });

      expect(response.statusCode, HttpStatus.ok);
      expect(await db.settingsDao.getSetting('sequencer_dither_pixels'), '2.5');
      expect(await db.settingsDao.getSetting('scheduler_config'), '{}');
      expect(container.read(settingsStoreRevisionProvider), revision + 1);
      final event = announced.single;
      expect(event.data['entityType'], HostMutationEntity.settings);
      expect(event.data['namespace'], 'store');
      expect((event.data['keys'] as List).toSet(), {
        'sequencer_dither_pixels',
        'scheduler_config',
      });
    },
  );

  test(
    'rows of the settings notifier without a typed field go through it',
    () async {
      await container.read(appSettingsProvider.future);

      final response = await post({
        'settings': {
          'mount_site_sync_mode': 'computerToMount',
          'horizon_profile_json': '{"N":10}',
        },
      });

      expect(response.statusCode, HttpStatus.ok);
      final state = container.read(appSettingsProvider).requireValue;
      expect(state.mountSiteSyncMode, 'computerToMount');
      expect(state.horizonProfileJson, '{"N":10}');
      expect(
        await db.settingsDao.getSetting('mount_site_sync_mode'),
        'computerToMount',
      );
    },
  );

  test('refuses typed settings, screen preferences and empty bodies', () async {
    await container.read(appSettingsProvider.future);

    for (final body in [
      {
        'settings': {'dither_every_frames': '4'},
      },
      {
        'settings': {'theme': 'light'},
      },
      {
        'remove': ['mount_site_sync_mode'],
      },
      <String, Object?>{},
    ]) {
      final response = await post(body);
      expect(response.statusCode, HttpStatus.badRequest, reason: '$body');
    }
    expect(await db.settingsDao.getSetting('theme'), isNot('light'));
  });

  test('remove deletes a row', () async {
    await db.settingsDao.setSetting('smart_night.drafts.v1', '[]');

    final response = await post({
      'remove': ['smart_night.drafts.v1'],
    });

    expect(response.statusCode, HttpStatus.ok);
    expect(await db.settingsDao.getSetting('smart_night.drafts.v1'), isNull);
  });

  test(
    'merge keeps the fields another writer changed in the same row',
    () async {
      const key = 'imaging_capture_settings_profile_1';
      await db.settingsDao.setSetting(
        key,
        jsonEncode({'exposureTime': 12.0, 'gain': 100, 'offset': 50}),
      );
      final changed = <Set<String>>[];
      final sub = container
          .read(settingsRowChangesProvider)
          .stream
          .listen(changed.add);
      addTearDown(sub.cancel);

      // A client changed only the gain; its whole copy (stale exposure 7.5)
      // rides along for hosts that cannot merge and must be ignored here.
      final response = await post({
        'settings': {
          key: jsonEncode({'exposureTime': 7.5, 'gain': 222, 'offset': 50}),
        },
        'merge': {
          key: {'gain': 222},
        },
      });

      expect(response.statusCode, HttpStatus.ok);
      final stored = jsonDecode((await db.settingsDao.getSetting(key))!) as Map;
      expect(stored['exposureTime'], 12.0);
      expect(stored['gain'], 222);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(jsonDecode((body['merged'] as Map)[key] as String)['gain'], 222);
      await Future<void>.delayed(Duration.zero);
      expect(changed.single, {key});
    },
  );

  test('merge onto a missing row starts from mergeBase', () async {
    const key = 'imaging_capture_settings_profile_9';
    final response = await post({
      'merge': {
        key: {'gain': 5},
      },
      'mergeBase': {
        key: {'exposureTime': 2.0, 'gain': 100, 'offset': 50},
      },
    });

    expect(response.statusCode, HttpStatus.ok);
    final stored = jsonDecode((await db.settingsDao.getSetting(key))!) as Map;
    expect(stored, {'exposureTime': 2.0, 'gain': 5, 'offset': 50});
  });

  test('refuses a merge that is not an object of fields', () async {
    final response = await post({
      'merge': {'imaging_capture_settings_profile_1': 'gain=5'},
    });
    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('says whether the asking link has admin access', () async {
    await container.read(appSettingsProvider.future);
    expect((await getStoreBody())['adminAccess'], isFalse);
    expect(
      (await getStoreBody(scope: HeadlessTokenScope.admin))['adminAccess'],
      isTrue,
    );
  });

  test('a link without admin access reads whether a credential row is set, '
      'never its value', () async {
    await db.settingsDao.setSettings({
      'discord_webhook': 'https://discord.com/api/webhooks/1/secret',
      'pushover_user': '',
    });
    await container.read(appSettingsProvider.future);

    final control = await getStore();
    expect(control['discord_webhook'], credentialSetMarker);
    expect(control['pushover_user'], '');

    final admin =
        (await getStoreBody(scope: HeadlessTokenScope.admin))['settings']
            as Map;
    expect(
      admin['discord_webhook'],
      'https://discord.com/api/webhooks/1/secret',
    );
  });

  test('a row saying where the host sends a credential changes only with '
      'admin access', () async {
    await container.read(appSettingsProvider.future);
    const mail = 'notification_transport_email';
    const backupTarget = 'cloud_sync_server_url';
    await db.settingsDao.setSettings({
      mail: '{"host":"smtp.example.org"}',
      backupTarget: 'https://dav.example.org',
    });

    for (final body in [
      {
        'settings': {mail: '{"host":"smtp.attacker.example"}'},
      },
      {
        'merge': {
          mail: {'host': 'smtp.attacker.example'},
        },
      },
      {
        'remove': [backupTarget],
      },
    ]) {
      final response = await post(body);
      expect(response.statusCode, HttpStatus.forbidden, reason: '$body');
      final error = jsonDecode(await response.readAsString()) as Map;
      expect(error['code'], 'credential_setting');
    }
    expect(
      await db.settingsDao.getSetting(mail),
      '{"host":"smtp.example.org"}',
    );
    expect(
      await db.settingsDao.getSetting(backupTarget),
      'https://dav.example.org',
    );
    expect(announced, isEmpty);

    final response = await post({
      'settings': {mail: '{"host":"smtp.new.example"}'},
    }, scope: HeadlessTokenScope.admin);
    expect(response.statusCode, HttpStatus.ok);
    expect(
      await db.settingsDao.getSetting(mail),
      '{"host":"smtp.new.example"}',
    );
  });

  test('a request the auth middleware never saw is not admin', () async {
    await container.read(appSettingsProvider.future);
    final response = await translateHandlerErrors(
      handlers.handleUpdateSettingsStore(
        Request(
          'POST',
          Uri.parse('http://localhost/api/settings/store'),
          body: jsonEncode({
            'settings': {'notification_transport_email': '{}'},
          }),
        ),
      ),
    );
    expect(response.statusCode, HttpStatus.forbidden);
  });
}
