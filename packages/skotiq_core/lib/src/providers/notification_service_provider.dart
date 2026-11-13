import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_router_provider.dart';
import 'settings_provider.dart';
import '../services/notification_service.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(
    readSettings: () => ref.read(appSettingsProvider).valueOrNull,
    readRouter: () {
      try {
        return ref.read(notificationRouterProvider);
      } catch (e) {
        // A container without the notification graph. The caller is told
        // nothing was sent; raising here would fail the work that only wanted
        // to mention it.
        developer.log(
          '[Notification] Router unavailable: $e',
          name: 'NotificationService',
          level: 900,
        );
        return null;
      }
    },
  );
});
