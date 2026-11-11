// In-app banner transport.
//
// Wraps the existing `UiNotificationNotifier` so the routing matrix
// can treat in-app banners as just another transport. The message's severity
// maps onto the four-level success/info/warning/error palette the UI notifier
// already speaks.

import '../../../models/backend/event_types.dart';
import '../../../models/notification/notification_categories.dart';
import '../../../providers/ui_notification_provider.dart';
import '../notification_presentation.dart';
import 'notification_transport.dart';

class InAppTransport extends NotificationTransport {
  final UiNotificationNotifier _notifier;

  InAppTransport(this._notifier);

  @override
  NotificationTransportKind get kind => NotificationTransportKind.inApp;

  @override
  String get name => 'In-app banner';

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    final title = message.title;
    final body = message.body;
    final deepLink = message.deepLink;
    switch (message.severity) {
      case EventSeverity.info:
        if (NotificationPresentation.of(message.category).inAppSuccess) {
          _notifier.showSuccess(body, title: title, deepLink: deepLink);
        } else {
          _notifier.showInfo(body, title: title, deepLink: deepLink);
        }
      case EventSeverity.warning:
        _notifier.showWarning(body, title: title, deepLink: deepLink);
      case EventSeverity.error:
      case EventSeverity.critical:
        _notifier.showError(body, title: title, deepLink: deepLink);
    }
    return NotificationResult.ok();
  }
}
