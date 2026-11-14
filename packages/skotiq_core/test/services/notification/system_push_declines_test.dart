// A phone push that is not sent is not reported as sent.
//
// Mobile push can sit on any routing row, and three things still keep a
// message off the phones: the category has no phone push, its switch under
// Mobile push is off, or nothing is listening (Remote Access off). None of
// them is a delivery, so none may come back as one.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/notification_router.dart';
import 'package:skotiq_core/src/services/notification/transports/notification_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/system_push_transport.dart';
import 'package:skotiq_core/src/services/notification_service.dart';
import 'package:skotiq_core/src/services/push_notification_service.dart';

class _InApp extends NotificationTransport {
  final List<String> sent = [];

  @override
  NotificationTransportKind get kind => NotificationTransportKind.inApp;

  @override
  String get name => 'In-app';

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    sent.add(message.title);
    return NotificationResult.ok();
  }
}

NotificationMessage _message(NotificationCategory category) =>
    NotificationMessage(category: category, title: 'Title', body: 'Body');

void main() {
  late PushNotificationService push;
  late List<PushNotification> onThePhone;
  StreamSubscription<PushNotification>? phone;

  void pairAPhone() {
    phone = push.notifications.listen(onThePhone.add);
  }

  setUp(() {
    push = PushNotificationService();
    onThePhone = [];
    phone = null;
  });

  tearDown(() async {
    await phone?.cancel();
    push.dispose();
  });

  group('the transport', () {
    test('sends an event whose switch is on, to a listening phone', () async {
      pairAPhone();
      final result = await SystemPushTransport(
        push,
      ).send(_message(NotificationCategory.sequenceCompleted));
      await Future<void>.delayed(Duration.zero);

      expect(result.success, isTrue);
      expect(result.skipped, isFalse);
      expect(onThePhone, hasLength(1));
    });

    test(
      'an event switched off under Mobile push is skipped, not sent',
      () async {
        pairAPhone();
        push.updateConfig(
          const PushNotificationConfig(notifySequenceCompleted: false),
        );
        final result = await SystemPushTransport(
          push,
        ).send(_message(NotificationCategory.sequenceCompleted));
        await Future<void>.delayed(Duration.zero);

        expect(result.success, isFalse);
        expect(result.skipped, isTrue);
        expect(result.error, contains('switched off under Mobile push'));
        expect(onThePhone, isEmpty);
      },
    );

    test('a category the phone feed does not carry is skipped', () async {
      pairAPhone();
      final result = await SystemPushTransport(
        push,
      ).send(_message(NotificationCategory.triggerFired));

      expect(result.skipped, isTrue);
      expect(result.success, isFalse);
      expect(onThePhone, isEmpty);
    });

    test('with nothing listening the push is skipped and says why', () async {
      final result = await SystemPushTransport(
        push,
      ).send(_message(NotificationCategory.sequenceCompleted));

      expect(result.skipped, isTrue);
      expect(result.error, contains('Remote Access is off'));
    });
  });

  group('the router', () {
    NotificationRouter routerWith(
      _InApp inApp,
      List<NotificationTransportKind> transports,
    ) => NotificationRouter(
      transports: [inApp, SystemPushTransport(push)],
      matrix: NotificationRoutingMatrix.defaults().withRule(
        NotificationCategory.sequenceCompleted,
        NotificationRoutingRule(transports: transports),
      ),
    );

    test('does not name Mobile push for an event switched off there', () async {
      pairAPhone();
      push.updateConfig(
        const PushNotificationConfig(notifySequenceCompleted: false),
      );
      final inApp = _InApp();
      final router = routerWith(inApp, const [
        NotificationTransportKind.inApp,
        NotificationTransportKind.systemPush,
      ]);
      addTearDown(router.dispose);

      final outcome = router.routeRendered(
        category: NotificationCategory.sequenceCompleted,
        title: 'Done',
        body: 'The run finished.',
      );
      await Future<void>.delayed(Duration.zero);

      expect(outcome.dispatched, [NotificationTransportKind.inApp]);
      expect(
        NotificationDispatch(outcome).describe(),
        isNot(contains('systemPush')),
      );
      expect(inApp.sent, ['Done']);
      expect(onThePhone, isEmpty);
    });

    test('reports nothing sent when Mobile push was the only transport and '
        'declined', () async {
      final inApp = _InApp();
      final router = routerWith(inApp, const [
        NotificationTransportKind.systemPush,
      ]);
      addTearDown(router.dispose);

      final outcome = router.routeRendered(
        category: NotificationCategory.sequenceCompleted,
        title: 'Done',
        body: 'The run finished.',
      );

      expect(outcome.anyDispatched, isFalse);
      expect(outcome.dropReason, contains('Remote Access is off'));
      expect(
        NotificationDispatch(outcome).describe(),
        startsWith('Nothing was sent'),
      );
    });

    test('a test send to Mobile push with nothing listening is not a '
        'success', () async {
      final router = routerWith(_InApp(), const [
        NotificationTransportKind.systemPush,
      ]);
      addTearDown(router.dispose);

      final result = await router.sendTest(
        NotificationTransportKind.systemPush,
      );

      expect(result.success, isFalse);
      expect(result.skipped, isTrue);
    });
  });
}
