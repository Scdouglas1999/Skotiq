import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/smart_notification_service.dart';
import 'current_screen_provider.dart';
import 'ui_notification_provider.dart';

final smartNotificationServiceProvider = Provider<SmartNotificationService>((
  ref,
) {
  return SmartNotificationService(
    notices: ref.read(uiNotificationProvider.notifier),
    currentScreen: () => ref.read(currentScreenProvider),
  );
});
