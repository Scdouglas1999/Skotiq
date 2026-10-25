import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/notification_service.dart';

/// The notification route table is the only thing standing between a 4am push
/// and the screen the operator expected. These pin the mapping itself, the
/// refusal to invent a destination for a payload nobody wrote, and the
/// cold-start replay that routes a tap the app was not running to receive.
void main() {
  group('payload → route', () {
    test('a Darkroom draft opens the recipe the dawn pass saved', () {
      expect(
        routeForNotificationPayload('darkroom_draft:412'),
        '/darkroom?recipe=412',
      );
    });

    test('a recipe id is percent-encoded into the query', () {
      // The producer writes an integer row id today, but the payload is an
      // opaque string on the wire: anything that reaches the query must be
      // encoded or a stray `&` would silently truncate the link.
      expect(
        routeForNotificationPayload('darkroom_draft:a b&c=d'),
        '/darkroom?recipe=${Uri.encodeComponent('a b&c=d')}',
      );
    });

    test('a Darkroom payload with no recipe still opens the Darkroom', () {
      expect(routeForNotificationPayload('darkroom_draft'), '/darkroom');
      expect(routeForNotificationPayload('darkroom_draft:'), '/darkroom');
    });

    test('a built target, its framing check and the Activity tab open in the '
        'Darkroom', () {
      expect(
        routeForNotificationPayload('darkroom_target:NGC 891'),
        '/darkroom?tab=targets&target=NGC+891',
      );
      expect(
        routeForNotificationPayload('darkroom_framing:M81'),
        '/darkroom?tab=targets&target=M81&view=framing',
      );
      expect(
        routeForNotificationPayload('darkroom_activity'),
        '/darkroom?tab=activity',
      );
    });

    test('the pre-existing arms are unchanged', () {
      expect(
        routeForNotificationPayload('image_ready:M31.fits'),
        '/imaging/preview/${Uri.encodeComponent('M31.fits')}',
      );
      expect(
        routeForNotificationPayload('sequence_complete:M31'),
        '/sequencer',
      );
      expect(routeForNotificationPayload('guiding_lost'), '/guiding');
      expect(routeForNotificationPayload('safety'), '/weather');
      expect(routeForNotificationPayload('push:weatherUnsafe'), '/dashboard');
    });

    test('an unrecognised type answers null rather than a fallback screen', () {
      expect(routeForNotificationPayload('not_a_type'), isNull);
      expect(routeForNotificationPayload('not_a_type:7'), isNull);
      // A near-miss on a real type must not be absorbed by a prefix match.
      expect(routeForNotificationPayload('darkroom'), isNull);
      expect(routeForNotificationPayload('darkroom_drafts:1'), isNull);
    });
  });

  group('tap outcomes', () {
    final service = MobileNotificationService();

    NotificationResponse tap(String? payload) => NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotification,
      payload: payload,
    );

    setUp(() {
      service.resetLaunchReplayForTesting();
      service.setNavigator((_) {});
    });

    test('a routable payload reaches the navigator', () {
      final seen = <String>[];
      service.setNavigator(seen.add);

      expect(
        service.handleNotificationResponse(tap('darkroom_draft:7')),
        NotificationTapOutcome.routed,
      );
      expect(seen, ['/darkroom?recipe=7']);
    });

    test('an unknown payload navigates nowhere and says so', () {
      final seen = <String>[];
      service.setNavigator(seen.add);

      expect(
        service.handleNotificationResponse(tap('who_wrote_this:9')),
        NotificationTapOutcome.unknownPayload,
      );
      expect(
        seen,
        isEmpty,
        reason: 'an unroutable payload must not land on an arbitrary screen',
      );
    });

    test('a payload-less tap is distinguished from an unknown one', () {
      expect(
        service.handleNotificationResponse(tap(null)),
        NotificationTapOutcome.noPayload,
      );
    });
  });

  group('cold-start replay', () {
    final service = MobileNotificationService();

    setUp(() => service.resetLaunchReplayForTesting());
    tearDown(() => service.resetLaunchReplayForTesting());

    NotificationAppLaunchDetails launched(String payload) =>
        NotificationAppLaunchDetails(
          true,
          notificationResponse: NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: payload,
          ),
        );

    test(
      'a tap that started the app routes once, not once per rebuild',
      () async {
        final seen = <String>[];
        service.setNavigator(seen.add);
        var reads = 0;
        service.launchDetailsReader = () async {
          reads++;
          return launched('darkroom_draft:31');
        };

        await service.handleLaunchNotification();
        await service.handleLaunchNotification();
        await service.handleLaunchNotification();

        expect(seen, ['/darkroom?recipe=31']);
        expect(reads, 1, reason: 'the once-only guard latches after the first');
      },
    );

    test('a launch that no notification caused routes nothing', () async {
      final seen = <String>[];
      service.setNavigator(seen.add);
      service.launchDetailsReader = () async =>
          const NotificationAppLaunchDetails(false);

      await service.handleLaunchNotification();

      expect(seen, isEmpty);
    });

    test('a platform failure does not latch the guard', () async {
      final seen = <String>[];
      service.setNavigator(seen.add);
      var attempts = 0;
      service.launchDetailsReader = () async {
        attempts++;
        if (attempts == 1) throw StateError('platform channel unavailable');
        return launched('darkroom_draft:5');
      };

      await service.handleLaunchNotification();
      expect(seen, isEmpty);

      // The retry a later rebuild makes still finds the launch tap.
      await service.handleLaunchNotification();
      expect(seen, ['/darkroom?recipe=5']);
    });
  });
}
