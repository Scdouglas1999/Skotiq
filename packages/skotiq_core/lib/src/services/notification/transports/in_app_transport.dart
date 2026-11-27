// In-app banner transport.
//
// Wraps the operator's on-screen notices (`UiNotices`) so the routing matrix
// can treat in-app banners as just another transport. The message's severity
// maps onto the four-level success/info/warning/error palette the UI notifier
// already speaks.

import '../../../models/app_screen.dart';
import '../../../models/backend/event_types.dart';
import '../../../models/notification/notification_categories.dart';
import '../ui_notices.dart';
import '../notification_presentation.dart';
import 'notification_transport.dart';

class InAppTransport extends NotificationTransport {
  final UiNotices _notifier;

  /// The screen the operator is looking at; null where there is none.
  final AppScreen Function()? _currentScreen;

  InAppTransport(this._notifier, {AppScreen Function()? currentScreen})
    : _currentScreen = currentScreen;

  @override
  NotificationTransportKind get kind => NotificationTransportKind.inApp;

  @override
  String get name => 'In-app banner';

  @override
  bool get isConfigured => true;

  @override
  String? declines(NotificationMessage message) {
    final screen = _currentScreen?.call();
    if (screen != null && message.quietOn.contains(screen)) {
      return 'The screen the operator is on already shows it';
    }
    return null;
  }

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    final declined = declines(message);
    if (declined != null) return NotificationResult.skipped(declined);
    final title = message.title;
    final body = message.body;
    final deepLink = message.deepLink;
    final presentation = NotificationPresentation.of(message.category);
    final duration = presentation.inAppDuration;
    switch (message.severity) {
      case EventSeverity.info:
        if (presentation.inAppSuccess) {
          _notifier.showSuccess(
            body,
            title: title,
            duration: duration,
            deepLink: deepLink,
          );
        } else {
          _notifier.showInfo(
            body,
            title: title,
            duration: duration,
            deepLink: deepLink,
          );
        }
      case EventSeverity.warning:
        _notifier.showWarning(
          body,
          title: title,
          duration: duration,
          deepLink: deepLink,
        );
      case EventSeverity.error:
      case EventSeverity.critical:
        _notifier.showError(
          body,
          title: title,
          duration: duration,
          deepLink: deepLink,
        );
    }
    return NotificationResult.ok();
  }
}
