// What each kind of link gets of the host's admin-only settings, over the
// real server with real tokens: every route and socket a settings value
// leaves the host through, and every route one is written through.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

class _MockProfileSettingsBackend extends Mock
    implements ProfileSettingsBackend {}

const _webhook = 'https://discord.com/api/webhooks/1/secret';
const _tokens = ['admin-token', 'control-token', 'view-token'];

void main() {
  late SkotiqDatabase db;
  late ProviderContainer container;
  late HeadlessApiServer server;
  late HttpClient client;

  setUpAll(() => registerFallbackValue(const AppSettings()));

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    await db.settingsDao.setSettings({
      'discord_webhook': _webhook,
      'pushover_key': '',
      'phd2_path': '/usr/bin/phd2',
      'plugin_enablement': '{"com.example.plugin":false}',
    });
    final profileBackend = _MockProfileSettingsBackend();
    when(() => profileBackend.getLocation()).thenAnswer((_) async => null);
    when(() => profileBackend.updateSettings(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
        profileSettingsBackendProvider.overrideWithValue(profileBackend),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.0.0', buildNumber: 1),
        ),
      ],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      scopedAuthTokens: const {
        'control-token': HeadlessTokenScope.control,
        'view-token': HeadlessTokenScope.view,
      },
      webSocketHeartbeatInterval: const Duration(hours: 1),
      webSocketHeartbeatTimeout: const Duration(hours: 2),
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
    await db.close();
  });

  Future<(int, Map<String, dynamic>)> call(
    String token,
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.actualPort}$path'),
    );
    request.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return (
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  }

  Future<StreamIterator<dynamic>> connect(
    String token, {
    String query = '',
  }) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.actualPort}'
      '/events?token=$token$query',
    );
    addTearDown(socket.close);
    final frames = StreamIterator<dynamic>(socket);
    addTearDown(frames.cancel);
    return frames;
  }

  Future<Map> nextWebhookEvent(StreamIterator<dynamic> frames) async {
    while (await frames.moveNext()) {
      final frame = jsonDecode(frames.current as String) as Map;
      if (frame['type'] == 'event' &&
          frame['eventType'] == settingsChangedEventType &&
          (frame['data'] as Map)['key'] == 'discordWebhook') {
        return frame;
      }
    }
    fail('the socket closed before the webhook change arrived');
  }

  test('the typed settings give a credential to an admin link, whether it is '
      'set to a control link, and nothing to a view link', () async {
    final (adminStatus, admin) = await call(
      'admin-token',
      'GET',
      '/api/settings',
    );
    expect(adminStatus, HttpStatus.ok);
    expect((admin['settings'] as Map)['discordWebhook'], _webhook);

    final (controlStatus, control) = await call(
      'control-token',
      'GET',
      '/api/settings',
    );
    expect(controlStatus, HttpStatus.ok);
    final settings = control['settings'] as Map;
    expect(settings['discordWebhook'], credentialSetMarker);
    expect(settings['pushoverKey'], '');
    expect(settings['phd2Path'], '/usr/bin/phd2');
    expect(jsonEncode(control), isNot(contains('webhooks/1/secret')));

    final (viewStatus, view) = await call('view-token', 'GET', '/api/settings');
    expect(viewStatus, HttpStatus.forbidden);
    expect(jsonEncode(view), isNot(contains('webhooks/1/secret')));
  });

  test('the key/value rows do the same', () async {
    final (_, admin) = await call('admin-token', 'GET', '/api/settings/store');
    expect((admin['settings'] as Map)['discord_webhook'], _webhook);
    expect(admin['adminAccess'], isTrue);

    final (controlStatus, control) = await call(
      'control-token',
      'GET',
      '/api/settings/store',
    );
    expect(controlStatus, HttpStatus.ok);
    expect(
      (control['settings'] as Map)['discord_webhook'],
      credentialSetMarker,
    );
    expect(control['adminAccess'], isFalse);
    expect(jsonEncode(control), isNot(contains('webhooks/1/secret')));

    final (viewStatus, _) = await call(
      'view-token',
      'GET',
      '/api/settings/store',
    );
    expect(viewStatus, HttpStatus.forbidden);
  });

  test('an admin change reaches each socket and the recent events as that '
      'link may read it', () async {
    final sockets = {for (final token in _tokens) token: await connect(token)};

    const changed = 'https://discord.com/api/webhooks/2/other';
    final (status, _) = await call('admin-token', 'POST', '/api/settings', {
      'settings': {'discordWebhook': changed},
    });
    expect(status, HttpStatus.ok);

    final live = {
      for (final token in _tokens)
        token: await nextWebhookEvent(sockets[token]!),
    };
    expect((live['admin-token']!['data'] as Map)['value'], changed);
    for (final token in const ['control-token', 'view-token']) {
      final data = live[token]!['data'] as Map;
      expect(data['key'], 'discordWebhook', reason: token);
      expect(data['value'], credentialSetMarker, reason: token);
    }

    final instance = live['admin-token']!['serverInstanceId'];
    for (final token in const ['control-token', 'view-token']) {
      final replayed = await nextWebhookEvent(
        await connect(token, query: '&since=0&instance=$instance'),
      );
      expect(replayed['replay'], isTrue, reason: token);
      expect(
        (replayed['data'] as Map)['value'],
        credentialSetMarker,
        reason: token,
      );

      final (recentStatus, recent) = await call(
        token,
        'GET',
        '/api/runtime/recent-events',
      );
      expect(recentStatus, HttpStatus.ok, reason: token);
      expect(jsonEncode(recent), contains(credentialSetMarker), reason: token);
      expect(jsonEncode(recent), isNot(contains('webhooks/')), reason: token);
    }
    final (_, adminRecent) = await call(
      'admin-token',
      'GET',
      '/api/runtime/recent-events',
    );
    expect(jsonEncode(adminRecent), contains(changed));
  });

  test('only an admin link changes a credential or a program the host runs, '
      'through either settings route', () async {
    final refused = <(String, Map<String, Object?>, String)>[
      (
        '/api/settings',
        {
          'settings': {'discordWebhook': 'https://attacker.example/hook'},
        },
        'credential_setting',
      ),
      (
        '/api/settings',
        {
          'settings': {'discordWebhook': ''},
        },
        'credential_setting',
      ),
      (
        '/api/settings',
        {
          'settings': {'phd2Path': '/tmp/not-phd2'},
        },
        'host_program_setting',
      ),
      (
        '/api/settings/store',
        {
          'settings': {'notification_transport_email': '{"host":"smtp.x"}'},
        },
        'credential_setting',
      ),
      (
        '/api/settings/store',
        {
          'settings': {'plugin_enablement': '{"com.example.plugin":true}'},
        },
        'host_program_setting',
      ),
      (
        '/api/settings/store',
        {
          'settings': {'home_assistant_discovery': '{"allowControl":true}'},
        },
        'credential_setting',
      ),
      (
        '/api/settings/store',
        {
          'settings': {'backup.directory': '/tmp', 'autosave.max_backups': '1'},
        },
        'admin_setting',
      ),
      (
        '/api/settings/store',
        {
          'settings': {'autosave.backup_enabled': 'false'},
        },
        'admin_setting',
      ),
      (
        '/api/settings/store',
        {
          'settings': {'catalog_base_url': 'https://attacker.example/'},
        },
        'admin_setting',
      ),
      (
        '/api/settings',
        {
          'settings': {'webServerPort': 9, 'webServerEnabled': false},
        },
        'admin_setting',
      ),
    ];
    for (final (path, body, code) in refused) {
      final (status, error) = await call('control-token', 'POST', path, body);
      expect(status, HttpStatus.forbidden, reason: '$body');
      expect(error['code'], code, reason: '$body');
      expect(
        error['message'],
        contains('only a link with admin access can change'),
      );
      expect(jsonEncode(error), isNot(contains('webhooks/1/secret')));

      // A view link is turned away by its scope before the setting is looked
      // at.
      final (viewStatus, _) = await call('view-token', 'POST', path, body);
      expect(viewStatus, HttpStatus.forbidden, reason: '$body');
    }

    final current = await container.read(appSettingsProvider.future);
    expect(current.discordWebhook, _webhook);
    expect(current.phd2Path, '/usr/bin/phd2');
    expect(
      await db.settingsDao.getSetting('plugin_enablement'),
      '{"com.example.plugin":false}',
    );
    for (final key in const [
      'notification_transport_email',
      'home_assistant_discovery',
      'backup.directory',
      'autosave.max_backups',
      'autosave.backup_enabled',
    ]) {
      expect(await db.settingsDao.getSetting(key), isNull, reason: key);
    }
    expect(current.webServerPort, isNot(9));
    expect(current.catalogBaseUrl, '');

    final (adminStatus, _) = await call(
      'admin-token',
      'POST',
      '/api/settings',
      {
        'settings': {'phd2Path': '/opt/phd2/phd2'},
      },
    );
    expect(adminStatus, HttpStatus.ok);
    expect(
      (await container.read(appSettingsProvider.future)).phd2Path,
      '/opt/phd2/phd2',
    );
  });

  test('a control link saving the document it read changes what it meant to '
      'and leaves the credential alone', () async {
    final (_, read) = await call('control-token', 'GET', '/api/settings');
    // This host has no observer site, and a save cannot set half of one.
    final document = Map<String, dynamic>.from(read['settings'] as Map)
      ..removeWhere((key, value) => value == null)
      ..['phd2Port'] = 4411;
    expect(document['discordWebhook'], credentialSetMarker);

    final (status, answer) = await call(
      'control-token',
      'POST',
      '/api/settings',
      {'settings': document},
    );
    expect(status, HttpStatus.ok, reason: '$answer');

    final current = await container.read(appSettingsProvider.future);
    expect(current.phd2Port, 4411);
    expect(current.discordWebhook, _webhook);
  });

  test('a field of the settings document the host does not keep is refused, '
      'not reported as updated', () async {
    for (final token in const ['control-token', 'admin-token']) {
      final (status, error) = await call(token, 'POST', '/api/settings', {
        'settings': {
          'updateChannel': 'beta',
          'updateServerUrl': 'https://attacker.example',
          'ditherEnabled': false,
        },
      });
      expect(status, HttpStatus.badRequest, reason: token);
      expect(error['message'], contains('updateChannel, updateServerUrl'));
      expect(error['message'], contains('nothing was changed'));
    }
    expect(
      (await container.read(appSettingsProvider.future)).ditherEnabled,
      isTrue,
    );

    // Sent back as the host served it, such a field is not a change.
    final (status, _) = await call('control-token', 'POST', '/api/settings', {
      'settings': {'updateChannel': 'stable', 'ditherEnabled': false},
    });
    expect(status, HttpStatus.ok);
    expect(
      (await container.read(appSettingsProvider.future)).ditherEnabled,
      isFalse,
    );
  });

  test('the routes that hold every setting stay with admin links', () async {
    for (final (method, path) in const [
      ('GET', '/api/files/browse'),
      ('GET', '/api/settings/home-assistant'),
      ('GET', '/api/self-test'),
      ('GET', '/api/plugins'),
    ]) {
      for (final token in const ['control-token', 'view-token']) {
        final (status, body) = await call(token, method, path);
        expect(status, HttpStatus.forbidden, reason: '$token $method $path');
        expect(body['requiredScope'] ?? body['requiredLevel'], 'admin');
      }
    }
    for (final token in const ['control-token', 'view-token']) {
      final (status, _) = await call(token, 'POST', '/api/backup/create', {});
      expect(status, HttpStatus.forbidden, reason: token);
    }
  });

  test('a control link checks a host folder; a view link does not', () async {
    final (viewStatus, _) = await call(
      'view-token',
      'POST',
      '/api/files/validate',
      {'path': '/etc'},
    );
    expect(viewStatus, HttpStatus.forbidden);

    final (status, body) = await call(
      'control-token',
      'POST',
      '/api/files/validate',
      {'path': '/etc'},
    );
    // Its scope lets it ask; /etc is outside the folders the host answers
    // about, and the refusal does not say which those are.
    expect(status, HttpStatus.forbidden);
    expect(body['error'], 'path_not_allowed');
    expect(body.containsKey('allowedRoots'), isFalse);
  });
}
