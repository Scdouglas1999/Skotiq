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

}

/// Provider for the smart notification service.
final smartNotificationServiceProvider = Provider<SmartNotificationService>((
  ref,
) {
  return SmartNotificationService(ref);
});
