import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui_notification_provider.dart';
import '../services/error_service.dart';
import 'logging_service_provider.dart';

final errorServiceProvider = Provider<ErrorService>((ref) {
  final service = ErrorService();
  final logging = ref.watch(loggingServiceProvider);
  service.setLoggingService(logging);

  final uiNotifier = ref.watch(uiNotificationProvider.notifier);
  service.setUiNotificationNotifier(uiNotifier);
  return service;
});
