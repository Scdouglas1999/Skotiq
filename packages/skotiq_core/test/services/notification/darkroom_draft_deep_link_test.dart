// The morning draft's deep link, from the router to the wire.
//
// A payload that reaches the phone with the recipe id stripped out is a tap
// that lands on a dashboard, which is what this whole path exists to avoid. The
// carriage is deliberately narrow — only [SystemPushTransport] declares the
// parameter — so these pin that the one transport with a route table receives
// it, that the eight without one are unaffected, and that it survives
// `toJson()`.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/notification_router.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/services/notification/transports/in_app_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/notification_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/system_push_transport.dart';
import 'package:skotiq_core/src/services/push_notification_service.dart';

/// An in-app transport that records what it was asked to send. It does NOT
/// declare the deep-link parameter, which is the point: the base signature is
/// untouched by a mobile concern.
class _RecordingTransport extends NotificationTransport {
  @override
  final NotificationTransportKind kind;

  final List<({NotificationCategory category, String title})> sent = [];

  _RecordingTransport(this.kind);

  @override
  String get name => kind.label;

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    sent.add((category: category, title: title));
    return NotificationResult.ok();
  }
}

void main() {
  ({
    NotificationRouter router,
    PushNotificationService push,
    _RecordingTransport inApp,
  })
  build() {
    final push = PushNotificationService(
      config: const PushNotificationConfig(),
    );
    final inApp = _RecordingTransport(NotificationTransportKind.inApp);
    return (
      router: NotificationRouter(
        transports: [inApp, SystemPushTransport(push)],
        matrix: NotificationRoutingMatrix.defaults(),
      ),
      push: push,
      inApp: inApp,
    );
  }

  test('the draft category reaches the phone by default', () {
    final rule = NotificationRoutingMatrix.defaults().ruleFor(
      NotificationCategory.darkroomDraftReady,
    );
    expect(
      rule.transports,
      contains(NotificationTransportKind.systemPush),
      reason: 'the person the morning message is for is asleep in another room',
    );
  });

  test(
    'routeRendered carries the payload to the push, not to the others',
    () async {
      final rig = build();
      final pushes = <PushNotification>[];
      final sub = rig.push.notifications.listen(pushes.add);

      rig.router.routeRendered(
        category: NotificationCategory.darkroomDraftReady,
        title: 'M31 — 3h 42m integrated',
        body: '112 frames used, 8 rejected.',
        deepLink: 'darkroom_draft:412',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(pushes, hasLength(1));
      expect(pushes.single.deepLink, 'darkroom_draft:412');
      expect(pushes.single.eventType, 'darkroomDraftReady');
      expect(pushes.single.category, EventCategory.imaging);
      expect(
        pushes.single.priority,
        PushNotificationPriority.normal,
        reason: 'the night is already over; nothing here is an emergency',
      );

      // The in-app transport still received the message, unchanged.
      expect(rig.inApp.sent, hasLength(1));
      expect(
        rig.inApp.sent.single.category,
        NotificationCategory.darkroomDraftReady,
      );
    },
  );

  test('a routed message with no payload carries none on the wire', () async {
    final rig = build();
    final pushes = <PushNotification>[];
    final sub = rig.push.notifications.listen(pushes.add);

    rig.router.routeRendered(
      category: NotificationCategory.darkroomDraftReady,
      title: 'Your draft is ready',
      body: 'No draft was rendered; the report says why.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await sub.cancel();

    expect(pushes, hasLength(1));
    expect(pushes.single.deepLink, isNull);
    expect(
      pushes.single.toJson().containsKey('deepLink'),
      isFalse,
      reason: 'an older phone build reads the map key-by-key',
    );
  });

  test('the payload survives toJson', () {
    final json = PushNotification(
      title: 'M31',
      body: 'ready',
      priority: PushNotificationPriority.normal,
      eventType: 'darkroomDraftReady',
      category: EventCategory.imaging,
      timestamp: DateTime.utc(2026, 8, 16),
      deepLink: 'darkroom_draft:412',
    ).toJson();

    expect(json['deepLink'], 'darkroom_draft:412');
  });

  test(
    'routeNotificationNode still routes as custom with no payload',
    () async {
      final rig = build();
      final pushes = <PushNotification>[];
      final sub = rig.push.notifications.listen(pushes.add);

      rig.router.routeNotificationNode(title: 'scripted', body: 'node');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(rig.inApp.sent.single.category, NotificationCategory.custom);
      expect(pushes, isEmpty, reason: 'custom is in-app only by default');
    },
  );

  test(
    'the in-app banner carries the payload so it can offer to open it',
    () async {
      final banners = UiNotificationNotifier();
      final router = NotificationRouter(
        transports: [InAppTransport(banners)],
        matrix: NotificationRoutingMatrix.defaults(),
      );
      router.routeRendered(
        category: NotificationCategory.darkroomDraftReady,
        title: 'Masters wait for the framing check: M81',
        body: 'The common crop keeps 55.0% of the field (minimum 80%).',
        deepLink: 'darkroom_framing:M81',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(banners.state.single.deepLink, 'darkroom_framing:M81');
      expect(
        banners.state.single.duration,
        const Duration(seconds: 15),
        reason: 'long enough to follow the link',
      );
    },
  );
}
