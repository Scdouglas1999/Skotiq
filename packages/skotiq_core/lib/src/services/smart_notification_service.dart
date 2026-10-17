import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/current_screen_provider.dart';
import '../providers/ui_notification_provider.dart';

/// Service for sending screen-aware notifications.
///
/// This service wraps the standard [UiNotificationNotifier] and adds
/// logic to conditionally show notifications only when the user is NOT
/// viewing the screen where the operation is happening.
///
/// For example, if the user is on the Imaging screen and a slew completes,
/// they can already see the slew result - no need for a notification.
/// But if they're on the Dashboard and a slew completes, they should be notified.
class SmartNotificationService {
  final Ref _ref;

  SmartNotificationService(this._ref);

  UiNotificationNotifier get _notifier =>
      _ref.read(uiNotificationProvider.notifier);

  /// Show a success notification only if the user is NOT on the specified screen.
  ///
  /// [message] - The notification message
  /// [relevantScreen] - The screen where this operation is visible; if the user
  ///                    is on this screen, no notification is shown
  /// [title] - Optional title for the notification
  void showSuccessIfNotOnScreen({
    required String message,
    required AppScreen relevantScreen,
    String? title,
  }) {
    final currentScreen = _ref.read(currentScreenProvider);
    if (currentScreen != relevantScreen) {
      _notifier.showSuccess(message, title: title);
    }
  }

  /// Show an info notification only if the user is NOT on the specified screen.
  void showInfoIfNotOnScreen({
    required String message,
    required AppScreen relevantScreen,
    String? title,
  }) {
    final currentScreen = _ref.read(currentScreenProvider);
    if (currentScreen != relevantScreen) {
      _notifier.showInfo(message, title: title);
    }
  }

  /// Show a warning notification only if the user is NOT on the specified screen.
  void showWarningIfNotOnScreen({
    required String message,
    required AppScreen relevantScreen,
    String? title,
  }) {
    final currentScreen = _ref.read(currentScreenProvider);
    if (currentScreen != relevantScreen) {
      _notifier.showWarning(message, title: title);
    }
  }

  /// Show an error notification only if the user is NOT on the specified screen.
  void showErrorIfNotOnScreen({
    required String message,
    required AppScreen relevantScreen,
    String? title,
  }) {
    final currentScreen = _ref.read(currentScreenProvider);
    if (currentScreen != relevantScreen) {
      _notifier.showError(message, title: title);
    }
  }

  /// Show a success notification only if the user is NOT on any of the specified screens.
  void showSuccessIfNotOnScreens({
    required String message,
    required List<AppScreen> relevantScreens,
    String? title,
  }) {
    final currentScreen = _ref.read(currentScreenProvider);
    if (!relevantScreens.contains(currentScreen)) {
      _notifier.showSuccess(message, title: title);
    }
  }

  /// Show a notification unconditionally (passthrough to standard notifier).
  void showSuccess(String message, {String? title}) {
    _notifier.showSuccess(message, title: title);
  }

  void showInfo(String message, {String? title}) {
    _notifier.showInfo(message, title: title);
  }

  void showWarning(String message, {String? title}) {
    _notifier.showWarning(message, title: title);
  }

  void showError(String message, {String? title}) {
    _notifier.showError(message, title: title);
  }
}

/// Provider for the smart notification service.
final smartNotificationServiceProvider = Provider<SmartNotificationService>((
  ref,
) {
  return SmartNotificationService(ref);
});
