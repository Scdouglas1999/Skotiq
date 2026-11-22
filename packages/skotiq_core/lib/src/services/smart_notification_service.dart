import '../models/app_screen.dart';
import 'notification/ui_notices.dart';

/// Service for sending screen-aware notifications.
///
/// This service wraps the operator's [UiNotices] and adds
/// logic to conditionally show notifications only when the user is NOT
/// viewing the screen where the operation is happening.
///
/// For example, if the user is on the Imaging screen and a slew completes,
/// they can already see the slew result - no need for a notification.
/// But if they're on the Dashboard and a slew completes, they should be notified.
class SmartNotificationService {
  SmartNotificationService({
    required UiNotices Function() notices,
    required AppScreen Function() currentScreen,
  }) : _notices = notices,
       _currentScreen = currentScreen;

  final UiNotices Function() _notices;

  UiNotices get _notifier => _notices();

  /// The screen the operator is looking at now.
  final AppScreen Function() _currentScreen;

  /// Show a success notification only if the user is NOT on any of the specified screens.
  void showSuccessIfNotOnScreens({
    required String message,
    required List<AppScreen> relevantScreens,
    String? title,
  }) {
    final currentScreen = _currentScreen();
    if (!relevantScreens.contains(currentScreen)) {
      _notifier.showSuccess(message, title: title);
    }
  }
}
