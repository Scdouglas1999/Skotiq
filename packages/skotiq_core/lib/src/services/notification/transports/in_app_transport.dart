// In-app banner transport.
//
// Wraps the existing `UiNotificationNotifier` so the routing matrix
// can treat in-app banners as just another transport. Severity is
// derived from the category default and mapped onto the four-level
// success/info/warning/error palette the UI notifier already speaks.

import '../../../models/backend/event_types.dart';
import '../../../models/notification/notification_categories.dart';
import '../../../providers/ui_notification_provider.dart';
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
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) => sendWithLink(category: category, title: title, body: body);

  /// [send], with the `type[:arg]` payload the banner offers to open.
  Future<NotificationResult> sendWithLink({
    required NotificationCategory category,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    final severity = category.defaultSeverity;
    switch (severity) {
      case EventSeverity.info:
        if (_isPositive(category)) {
          _notifier.showSuccess(body, title: title, deepLink: deepLink);
        } else {
          _notifier.showInfo(body, title: title, deepLink: deepLink);
        }
        break;
      case EventSeverity.warning:
        _notifier.showWarning(body, title: title, deepLink: deepLink);
        break;
      case EventSeverity.error:
      case EventSeverity.critical:
        _notifier.showError(body, title: title, deepLink: deepLink);
        break;
    }
    return NotificationResult.ok();
  }

  bool _isPositive(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.sequenceCompleted:
      case NotificationCategory.targetCompleted:
      case NotificationCategory.recoveryRecovered:
      case NotificationCategory.guidingRecovered:
      case NotificationCategory.weatherSafeAgain:
      case NotificationCategory.cloudOpening:
      case NotificationCategory.autofocusCompleted:
        return true;
      default:
        return false;
    }
  }
}
