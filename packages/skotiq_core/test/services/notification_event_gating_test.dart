// `notifyOnSequenceComplete` / `notifyOnError` / `notifyOnMeridianFlip` are
// live delivery gates, not bookkeeping: `_shouldNotifyForEvent` makes `notify()`
// return early on a false, so the family's alert sound and everything the
// router would have sent are suppressed.
//
// This was mis-read once as "no delivery path reads them", and Settings shipped
// the three switches disabled on the strength of it. The tests below assert the
// behaviour that claim denied — including that `notifyOnMeridianFlip` ships
// `false`, which is what silently dropped the flip monitor's alerts.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/notification_service.dart';

import 'notification/recording_router.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

const _webhookSettings = AppSettingsState(
  notificationsEnabled: true,
  soundEnabled: false,
);

/// Runs [notify] against a service whose router records every send.
Future<({bool sent, int posts, int sounds})> _dispatch(
  AppSettingsState settings,
  NotificationEvent event,
) async {
  var sounds = 0;
  final recording = recordingRouter();
  final service = NotificationService(
    readSettings: () => settings,
    readRouter: () => recording.router,
    soundPlayer: () async => sounds++,
  );
  final dispatch = await service.notify(
    event: event,
    title: 'title',
    message: 'message',
  );
  await Future<void>.delayed(Duration.zero);
  return (
    sent: dispatch.anyDelivered,
    posts: recording.transports.values.single.sent.length,
    sounds: sounds,
  );
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
          reason: 'a false flag must stop the send, not just the return',
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

    test('the family without a flag of its own always passes', () async {
      final result = await _dispatch(
        _webhookSettings,
        NotificationEvent.custom,
      );
      expect(result.sent, isTrue);
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
      const shipped = AppSettingsState(notificationsEnabled: true);

      expect(shipped.notificationsEnabled, isTrue);
      expect(shipped.notifyOnMeridianFlip, isFalse);
    });
  });
}
