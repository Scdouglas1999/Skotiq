import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/notification_service.dart';

import 'notification/recording_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationService sound gating', () {
    test('plays sound when soundEnabled is true', () async {
      // Why: the desktop "Sound alerts" toggle gates platform sound
      // playback per The
      // notification dispatch path must call the sound player exactly
      // once when the toggle is on.
      var playCount = 0;
      const settings = AppSettingsState(
        notificationsEnabled: true,
        notifyOnSequenceComplete: true,
        soundEnabled: true,
      );
      final service = NotificationService(
        readSettings: () => settings,
        readRouter: () => recordingRouter().router,
        soundPlayer: () async {
          playCount++;
        },
      );

      await service.notify(
        event: NotificationEvent.sequenceComplete,
        title: 'Done',
        message: 'Sequence finished',
      );

      // Allow the unawaited fire-and-forget call to complete.
      await Future<void>.delayed(Duration.zero);
      expect(playCount, 1);
    });

    test('does not play sound when soundEnabled is false', () async {
      var playCount = 0;
      const settings = AppSettingsState(
        notificationsEnabled: true,
        notifyOnSequenceComplete: true,
        soundEnabled: false,
      );
      final service = NotificationService(
        readSettings: () => settings,
        readRouter: () => recordingRouter().router,
        soundPlayer: () async {
          playCount++;
        },
      );

      await service.notify(
        event: NotificationEvent.sequenceComplete,
        title: 'Done',
        message: 'Sequence finished',
      );

      await Future<void>.delayed(Duration.zero);
      expect(playCount, 0);
    });

    test(
      'does not play sound when notifications are entirely disabled',
      () async {
        var playCount = 0;
        const settings = AppSettingsState(
          notificationsEnabled: false,
          soundEnabled: true,
        );
        final service = NotificationService(
          readSettings: () => settings,
          readRouter: () => recordingRouter().router,
          soundPlayer: () async {
            playCount++;
          },
        );

        await service.notify(
          event: NotificationEvent.sequenceComplete,
          title: 'Done',
          message: 'Sequence finished',
        );

        await Future<void>.delayed(Duration.zero);
        expect(playCount, 0);
      },
    );
  });
}
