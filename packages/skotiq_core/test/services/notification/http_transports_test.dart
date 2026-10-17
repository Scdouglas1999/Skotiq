import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/models/notification/transport_configs.dart';
import 'package:skotiq_core/src/services/notification/transports/discord_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/pushover_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/telegram_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/webhook_transport.dart';

void main() {
  group('PushoverTransport', () {
    test('unconfigured -> fail', () async {
      final t = PushoverTransport(
        config: const PushoverTransportConfig(),
        httpClient: MockClient((req) async => http.Response('ok', 200)),
      );
      expect(t.isConfigured, isFalse);
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 'X',
        body: 'Y',
      );
      expect(res.success, isFalse);
      await t.dispose();
    });

    test(
      'configured -> hits the api endpoint with token + user + message',
      () async {
        late http.Request capturedReq;
        final t = PushoverTransport(
          config: const PushoverTransportConfig(
            apiToken: 'TOK',
            userKey: 'USR',
          ),
          httpClient: MockClient((req) async {
            capturedReq = req;
            return http.Response('{"status":1}', 200);
          }),
        );
        final res = await t.send(
          category: NotificationCategory.targetCompleted,
          title: 'Hello',
          body: 'World',
        );
        expect(res.success, isTrue);
        expect(capturedReq.url.host, contains('pushover'));
        expect(capturedReq.bodyFields['token'], 'TOK');
        expect(capturedReq.bodyFields['user'], 'USR');
        expect(capturedReq.bodyFields['title'], 'Hello');
        expect(capturedReq.bodyFields['message'], 'World');
        await t.dispose();
      },
    );

    test('non-200 response -> failure with status code', () async {
      final t = PushoverTransport(
        config: const PushoverTransportConfig(apiToken: 'TOK', userKey: 'USR'),
        httpClient: MockClient((req) async => http.Response('bad', 401)),
      );
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 't',
        body: 'b',
      );
      expect(res.success, isFalse);
      expect(res.statusCode, 401);
      await t.dispose();
    });
  });

  group('TelegramTransport', () {
    test('unconfigured -> fail', () async {
      final t = TelegramTransport(
        config: const TelegramTransportConfig(),
        httpClient: MockClient((req) async => http.Response('ok', 200)),
      );
      expect(t.isConfigured, isFalse);
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 'X',
        body: 'Y',
      );
      expect(res.success, isFalse);
      await t.dispose();
    });

    test(
      'configured -> posts to /bot<token>/sendMessage with chat_id',
      () async {
        late http.Request captured;
        final t = TelegramTransport(
          config: const TelegramTransportConfig(botToken: 'BOT', chatId: '@me'),
          httpClient: MockClient((req) async {
            captured = req;
            return http.Response('{"ok":true,"result":{}}', 200);
          }),
        );
        final res = await t.send(
          category: NotificationCategory.targetCompleted,
          title: 'Hi',
          body: 'There',
        );
        expect(res.success, isTrue);
        expect(captured.url.path, '/botBOT/sendMessage');
        expect(captured.bodyFields['chat_id'], '@me');
        expect(captured.bodyFields['text'], contains('Hi'));
        expect(captured.bodyFields['text'], contains('There'));
        await t.dispose();
      },
    );

    test('server returns ok=false -> failure with description', () async {
      final t = TelegramTransport(
        config: const TelegramTransportConfig(botToken: 'B', chatId: '1'),
        httpClient: MockClient(
          (req) async =>
              http.Response('{"ok":false,"description":"bad chat"}', 200),
        ),
      );
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 't',
        body: 'b',
      );
      expect(res.success, isFalse);
      expect(res.error, contains('bad chat'));
      await t.dispose();
    });
  });

  group('DiscordTransport', () {
    test('unconfigured -> fail', () async {
      final t = DiscordTransport(
        config: const DiscordTransportConfig(),
        httpClient: MockClient((req) async => http.Response('', 204)),
      );
      expect(t.isConfigured, isFalse);
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 'X',
        body: 'Y',
      );
      expect(res.success, isFalse);
      await t.dispose();
    });

    test('sends embed-style JSON to webhook url', () async {
      late http.Request captured;
      final t = DiscordTransport(
        config: const DiscordTransportConfig(
          webhookUrl: 'https://discord.com/api/webhooks/x/y',
          username: 'SkotiqBot',
        ),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('', 204);
        }),
      );
      final res = await t.send(
        category: NotificationCategory.sequenceFailed,
        title: 'Boom',
        body: 'Reason',
      );
      expect(res.success, isTrue);
      final decoded = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(decoded['username'], 'SkotiqBot');
      expect((decoded['embeds'] as List).first['title'], 'Boom');
      expect((decoded['embeds'] as List).first['description'], 'Reason');
      // Sequence-failed should colour red:
      expect((decoded['embeds'] as List).first['color'], 0xEF4444);
      await t.dispose();
    });

    test('non-2xx -> failure', () async {
      final t = DiscordTransport(
        config: const DiscordTransportConfig(
          webhookUrl: 'https://discord.com/api/webhooks/x/y',
        ),
        httpClient: MockClient((req) async => http.Response('err', 500)),
      );
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 't',
        body: 'b',
      );
      expect(res.success, isFalse);
      expect(res.statusCode, 500);
      await t.dispose();
    });
  });

  group('WebhookTransport', () {
    test('unconfigured -> fail', () async {
      final t = WebhookTransport(
        config: const WebhookTransportConfig(),
        httpClient: MockClient((req) async => http.Response('ok', 200)),
      );
      expect(t.isConfigured, isFalse);
      final res = await t.send(
        category: NotificationCategory.custom,
        title: 'X',
        body: 'Y',
      );
      expect(res.success, isFalse);
      await t.dispose();
    });

    test('default body is JSON with category + title + body', () async {
      late http.Request captured;
      final t = WebhookTransport(
        config: const WebhookTransportConfig(url: 'https://example.com/hook'),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('ok', 200);
        }),
      );
      await t.send(
        category: NotificationCategory.targetCompleted,
        title: 'T',
        body: 'B',
      );
      final decoded = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(decoded['category'], 'targetCompleted');
      expect(decoded['title'], 'T');
      expect(decoded['body'], 'B');
      expect(captured.headers['content-type'], contains('json'));
      await t.dispose();
    });

    test('user-supplied body template is rendered', () async {
      late http.Request captured;
      final t = WebhookTransport(
        config: const WebhookTransportConfig(
          url: 'https://example.com/hook',
          bodyTemplate: r'{"text":"${title} -- ${body}"}',
        ),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('ok', 200);
        }),
      );
      await t.send(
        category: NotificationCategory.custom,
        title: 'Hello',
        body: 'World',
      );
      final decoded = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(decoded['text'], 'Hello -- World');
      await t.dispose();
    });

    test('escapes user-supplied content so JSON stays valid', () async {
      late http.Request captured;
      final t = WebhookTransport(
        config: const WebhookTransportConfig(
          url: 'https://example.com/hook',
          bodyTemplate: r'{"msg":"${title}"}',
        ),
        httpClient: MockClient((req) async {
          captured = req;
          return http.Response('ok', 200);
        }),
      );
      await t.send(
        category: NotificationCategory.custom,
        title: 'has "quotes" and \\backslash',
        body: '',
      );
      // Must parse as valid JSON.
      final decoded = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(decoded['msg'], 'has "quotes" and \\backslash');
      await t.dispose();
    });
  });
}
