// GET/POST /api/settings/store: the host's key/value settings rows a linked
// client mirrors.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/profile_handlers.dart';
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

  Future<Response> post(Map<String, Object?> body) => translateHandlerErrors(
    handlers.handleUpdateSettingsStore(
      Request(
        'POST',
        Uri.parse('http://localhost/api/settings/store'),
        body: jsonEncode(body),
      ),
    ),
  );

  Future<Map<String, dynamic>> getStore() async {
    final response = await handlers.handleGetSettingsStore(
      Request('GET', Uri.parse('http://localhost/api/settings/store')),
    );
    expect(response.statusCode, HttpStatus.ok);
    final body = jsonDecode(await response.readAsString()) as Map;
    return (body['settings'] as Map).cast<String, dynamic>();
  }

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
}
