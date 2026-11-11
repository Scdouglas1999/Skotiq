// System (mobile) push transport — the SINGLE systemPush producer.
//
// The `NotificationRouter` routes a category to this transport per the
// routing matrix; this transport applies the per-event
// [PushNotificationConfig] switch and the category's phone priority and event
// kind from [NotificationPresentation], then broadcasts a [PushNotification]
// via [PushNotificationService]. Paired phones receive it over the WebSocket
// envelope they already listen to.

import '../../../models/backend/event_types.dart' as core;
import '../../../models/notification/notification_categories.dart';
import '../../push_notification_service.dart';
import '../notification_presentation.dart';
import 'notification_transport.dart';

class SystemPushTransport extends NotificationTransport {
  final PushNotificationService _service;

  SystemPushTransport(this._service);

  @override
  NotificationTransportKind get kind => NotificationTransportKind.systemPush;

  @override
  String get name => 'Mobile push';

  /// Configured only while the authoritative master gate is enabled. This
  /// keeps a disabled/fail-closed push feed from consuming router debounce and
  /// rate-limit slots for messages that cannot actually leave the service.
  @override
  bool get isConfigured => _service.config.enabled;

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    final presentation = NotificationPresentation.of(message.category);
    final push = presentation.push;
    // A category the phone feed does not escalate, or one whose per-event
    // switch is off, is a no-op success: the matrix may list systemPush on
    // the rule without this transport second-guessing it.
    if (push == null) return NotificationResult.ok();
    final toggle = push.toggle;
    if (toggle != null && !_service.config.allows(toggle)) {
      return NotificationResult.ok();
    }

    _service.enqueue(
      PushNotification(
        title: message.title,
        body: message.body,
        priority: push.priority,
        eventType: message.category.storageKey,
        category: presentation.eventCategory,
        timestamp: DateTime.now(),
        deepLink: message.deepLink,
      ),
    );
    return NotificationResult.ok();
  }

  /// Enqueue an EXPLICIT, forced-priority phone push with already-rendered
  /// copy, bypassing the per-category toggle/priority inference.
  ///
  /// Used only by `NotificationRouter.routeCriticalPush`, for alerts that
  /// have no [NotificationCategory] and must still page the operator. The
  /// master `enabled` gate is still enforced inside
  /// [PushNotificationService.enqueue].
  void enqueueExplicit({
    required String title,
    required String body,
    required String eventType,
    required core.EventCategory eventCategory,
    PushNotificationPriority priority = PushNotificationPriority.critical,
  }) {
    _service.enqueue(
      PushNotification(
        title: title,
        body: body,
        priority: priority,
        eventType: eventType,
        category: eventCategory,
        timestamp: DateTime.now(),
      ),
    );
  }
}
