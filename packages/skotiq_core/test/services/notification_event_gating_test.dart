// `notifyOnSequenceComplete` / `notifyOnError` / `notifyOnMeridianFlip` are
// live delivery gates, not bookkeeping: `_shouldNotifyForEvent` makes `notify()`
// return early on a false, so the family's alert sound, Discord post and
// Pushover push are all suppressed.
//
// This was mis-read once as "no delivery path reads them", and Settings shipped
// the three switches disabled on the strength of it. The tests below assert the
// behaviour that claim denied — including that `notifyOnMeridianFlip` ships
// `false`, which is what silently dropped the flip monitor's alerts.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/notification_service.dart';

const _webhookSettings = AppSettingsState(
  notificationsEnabled: true,
  soundEnabled: false,
  discordWebhook: 'https://discord.com/api/webhooks/test',
);

/// Runs [notify] against a service whose transports record every call.
Future<({bool sent, int posts, int sounds})> _dispatch(
  AppSettingsState settings,
  NotificationEvent event,
) async {
  var posts = 0;
  var sounds = 0;
  final service = NotificationService.testing(
    settingsReader: () => settings,
    httpClient: MockClient((_) async {
      posts++;
      return http.Response('ok', 200);
    }),
    soundPlayer: () async => sounds++,
  );
  final sent = await service.notify(
    event: event,
    title: 'title',
    message: 'message',
  );
  await Future<void>.delayed(Duration.zero);
  service.dispose();
  return (sent: sent, posts: posts, sounds: sounds);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-family gating', () {
    const families = {
      NotificationEvent.sequenceComplete: 'notifyOnSequenceComplete',
      NotificationEvent.error: 'notifyOnError',
      NotificationEvent.meridianFlip: 'notifyOnMeridianFlip',
    };

    AppSettingsState settingsWith(NotificationEvent event, bool value) {
      switch (event) {
        case NotificationEvent.sequenceComplete:
          return _webhookSettings.copyWith(notifyOnSequenceComplete: value);
        case NotificationEvent.error:
          return _webhookSettings.copyWith(notifyOnError: value);
        case NotificationEvent.meridianFlip:
          return _webhookSettings.copyWith(notifyOnMeridianFlip: value);
        case NotificationEvent.captureComplete:
        case NotificationEvent.autofocusComplete:
        case NotificationEvent.custom:
          return _webhookSettings;
      }
    }

    for (final entry in families.entries) {
      test('${entry.value} = false suppresses the whole dispatch', () async {
        final result = await _dispatch(
          settingsWith(entry.key, false),
          entry.key,
        );

        expect(result.sent, isFalse);
        expect(
          result.posts,
          0,
          reason: 'a false flag must stop the webhook, not just the return',
        );
      });

      test('${entry.value} = true lets the dispatch through', () async {
        final result = await _dispatch(
          settingsWith(entry.key, true),
          entry.key,
        );

        expect(result.sent, isTrue);
        expect(result.posts, greaterThan(0));
      });
    }

    test('a gated family plays no alert sound either', () async {
      final result = await _dispatch(
        _webhookSettings.copyWith(
          soundEnabled: true,
          notifyOnMeridianFlip: false,
        ),
        NotificationEvent.meridianFlip,
      );

      expect(result.sounds, 0);
      expect(result.sent, isFalse);
    });

    test('families without a flag of their own always pass', () async {
      for (final event in const [
        NotificationEvent.captureComplete,
        NotificationEvent.autofocusComplete,
        NotificationEvent.custom,
      ]) {
        final result = await _dispatch(_webhookSettings, event);
        expect(result.sent, isTrue, reason: '$event should not be gated');
      }
    });
  });

  group('shipped defaults', () {
    test('meridian flip is off out of the box; the other two are on', () {
      const shipped = AppSettingsState();
      expect(shipped.notifyOnSequenceComplete, isTrue);
      expect(shipped.notifyOnError, isTrue);
      expect(shipped.notifyOnMeridianFlip, isFalse);
    });

    test('the default drops a meridian-flip alert with no other opt-out', () {
      // The defect in one assertion: nothing is disabled, nothing is
      // misconfigured, and the flip alert still never leaves the host.
      const shipped = AppSettingsState(
        notificationsEnabled: true,
        discordWebhook: 'https://discord.com/api/webhooks/test',
      );

      expect(shipped.notificationsEnabled, isTrue);
      expect(shipped.discordWebhook, isNotEmpty);
      expect(shipped.notifyOnMeridianFlip, isFalse);
    });
  });
}
