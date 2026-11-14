// One send path: the router's transports are the only thing that posts to
// Discord or Pushover, and an install that configured them before the router
// existed keeps receiving what it received.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _FakeDiagnosticsBackend implements DiagnosticsBackend {
  final StreamController<SkotiqEvent> events =
      StreamController<SkotiqEvent>.broadcast();

  @override
  Stream<SkotiqEvent> get eventStream => events.stream;

  @override
  bool get dispatchPluginNodesLocally => false;

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => const Stream.empty();

  @override
  void dispose() {}

  @override
  Future<LocationSettings> getLocationFromInternet() =>
      throw UnimplementedError('not needed for this test');
}

const _legacyUrl = 'https://discord.com/api/webhooks/legacy';
const _transportUrl = 'https://discord.com/api/webhooks/transport';
const _pushoverUrl = 'https://api.pushover.net/1/messages.json';

class _Install {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final keyring = InMemorySecureKeyValueStore();
  final requests = <http.Request>[];

  /// One app launch against this install's database and keyring.
  Future<T> launch<T>(Future<T> Function(ProviderContainer) body) {
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('ok', 200);
    });
    return http.runWithClient(() async {
      final backend = _FakeDiagnosticsBackend();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretsStoreProvider.overrideWithValue(SecretsStore(keyring)),
          diagnosticsBackendProvider.overrideWithValue(backend),
        ],
      );
      try {
        await container.read(appSettingsProvider.future);
        return await body(container);
      } finally {
        container.dispose();
        await backend.events.close();
      }
    }, () => client);
  }

  /// What the pre-router build left behind: credentials in app settings only.
  Future<void> configureAsBefore({
    String discord = '',
    String pushoverKey = '',
    String pushoverUser = '',
  }) => launch((container) async {
    final settings = container.read(appSettingsProvider.notifier);
    await settings.setDiscordWebhook(discord);
    await settings.setPushoverKey(pushoverKey);
    await settings.setPushoverUser(pushoverUser);
  });

  List<Uri> get posts => [for (final r in requests) r.url];
}

Future<void> _startRouting(ProviderContainer container) async {
  await container.read(discordTransportConfigProvider.future);
  await container.read(pushoverTransportConfigProvider.future);
  await container.read(notificationRoutingMatrixProvider.future);
  container.read(notificationRouterProvider);
  await _settle();
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a built-in alert reaches Discord once when the earlier webhook and '
    'the Discord transport are both set and the Custom row names Discord',
    () async {
      // At c04d55c8d this posted twice: once to each URL.
      final install = _Install();
      addTearDown(install.db.close);
      await install.configureAsBefore(discord: _legacyUrl);
      await install.launch((container) async {
        await _startRouting(container);
        await container
            .read(discordTransportConfigProvider.notifier)
            .save(const DiscordTransportConfig(webhookUrl: _transportUrl));
        await _settle();
        await container
            .read(notificationServiceProvider)
            .notifyError(errorTitle: 'Save failed', errorMessage: 'Disk full');
        await _settle();
      });

      expect(install.posts, [Uri.parse(_transportUrl)]);
    },
  );

  test('an install with only the earlier Discord webhook keeps receiving the '
      'built-in alerts and the morning message, with nothing to do', () async {
    final install = _Install();
    addTearDown(install.db.close);
    await install.configureAsBefore(discord: _legacyUrl);

    await install.launch((container) async {
      await _startRouting(container);
      final service = container.read(notificationServiceProvider);
      await service.notifyError(
        errorTitle: 'Save failed',
        errorMessage: 'Disk full',
      );
      await service.notify(
        event: NotificationEvent.sequenceComplete,
        title: 'Masters ready: NGC891',
        message: 'Two masters.',
        routeAs: NotificationCategory.darkroomDraftReady,
      );
      await _settle();

      expect(
        container.read(appSettingsProvider).requireValue.discordWebhook,
        _legacyUrl,
        reason: 'the earlier setting is carried, never blanked',
      );
      expect(
        container.read(configuredNotificationTransportsProvider),
        contains(NotificationTransportKind.discord),
      );
    });

    expect(install.posts, [Uri.parse(_legacyUrl), Uri.parse(_legacyUrl)]);
    final embeds = [
      for (final r in install.requests)
        (jsonDecode(r.body)['embeds'] as List).single as Map<String, dynamic>,
    ];
    expect(embeds[0]['title'], 'Error: Save failed');
    expect(embeds[0]['description'], 'Disk full');
    expect(embeds[0]['color'], 0xEF4444, reason: 'an error is still red');
    expect(embeds[1]['title'], 'Masters ready: NGC891');

    // The carry-over happened once: a second launch sends once more, to the
    // same place, and a row the user has since edited is left alone.
    install.requests.clear();
    await install.launch((container) async {
      await _startRouting(container);
      final matrix = container
          .read(notificationRoutingMatrixProvider)
          .requireValue;
      await container
          .read(notificationRoutingMatrixProvider.notifier)
          .setRule(
            NotificationCategory.darkroomDraftReady,
            matrix
                .ruleFor(NotificationCategory.darkroomDraftReady)
                .copyWith(transports: const [NotificationTransportKind.inApp]),
          );
    });
    await install.launch((container) async {
      await _startRouting(container);
      expect(
        container
            .read(notificationRoutingMatrixProvider)
            .requireValue
            .ruleFor(NotificationCategory.darkroomDraftReady)
            .transports,
        const [NotificationTransportKind.inApp],
      );
      await container
          .read(notificationServiceProvider)
          .notifyError(errorTitle: 'Save failed', errorMessage: 'Disk full');
      await _settle();
    });
    expect(install.posts, [Uri.parse(_legacyUrl)]);
  });

  test('an install with only the earlier Pushover keys keeps receiving, at '
      'the priorities it had', () async {
    final install = _Install();
    addTearDown(install.db.close);
    await install.configureAsBefore(
      pushoverKey: 'app-token',
      pushoverUser: 'u',
    );

    await install.launch((container) async {
      await _startRouting(container);
      final service = container.read(notificationServiceProvider);
      await service.notifyError(errorTitle: 'Lost', errorMessage: 'Camera');
      await service.notify(
        event: NotificationEvent.custom,
        title: 'Device Reconnected',
        message: 'Camera is back.',
      );
      await _settle();
    });

    expect(install.posts, [Uri.parse(_pushoverUrl), Uri.parse(_pushoverUrl)]);
    final first = install.requests[0].bodyFields;
    expect(first['token'], 'app-token');
    expect(first['user'], 'u');
    expect(first['title'], 'Error: Lost');
    expect(first['priority'], '1');
    expect(install.requests[1].bodyFields['priority'], '0');
  });

  test('the carry-over never replaces a credential the transport already '
      'holds', () async {
    final install = _Install();
    addTearDown(install.db.close);
    await SecretsStore(
      install.keyring,
    ).write(SecretField.discordWebhookUrl, _transportUrl);
    await install.configureAsBefore(discord: _legacyUrl);

    await install.launch((container) async {
      await _startRouting(container);
      expect(
        container.read(discordTransportConfigProvider).requireValue.webhookUrl,
        _transportUrl,
      );
    });
  });

  test('a linked client that edits the synced Discord setting changes the '
      'host transport', () async {
    final install = _Install();
    addTearDown(install.db.close);
    await install.configureAsBefore(discord: _legacyUrl);

    await install.launch((container) async {
      await _startRouting(container);
      // What the settings sync does on the host when a client edits the row.
      await container
          .read(appSettingsProvider.notifier)
          .setDiscordWebhook(_transportUrl);
      await _settle();
      expect(
        container.read(discordTransportConfigProvider).requireValue.webhookUrl,
        _transportUrl,
      );
    });
  });

  test('saving the transport keeps an existing synced copy in step and never '
      'creates one', () async {
    final withCopy = _Install();
    addTearDown(withCopy.db.close);
    await withCopy.configureAsBefore(discord: _legacyUrl);
    await withCopy.launch((container) async {
      await _startRouting(container);
      await container
          .read(discordTransportConfigProvider.notifier)
          .save(const DiscordTransportConfig(webhookUrl: _transportUrl));
      expect(
        container.read(appSettingsProvider).requireValue.discordWebhook,
        _transportUrl,
      );
    });

    final fresh = _Install();
    addTearDown(fresh.db.close);
    await fresh.launch((container) async {
      await _startRouting(container);
      await container
          .read(discordTransportConfigProvider.notifier)
          .save(const DiscordTransportConfig(webhookUrl: _transportUrl));
      expect(
        container.read(appSettingsProvider).requireValue.discordWebhook,
        isEmpty,
        reason: 'a secret is not copied out of the keyring',
      );
    });
  });
}
