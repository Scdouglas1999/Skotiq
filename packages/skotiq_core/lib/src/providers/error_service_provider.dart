import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui_notification_provider.dart';
import '../services/error_service.dart';
import 'logging_service_provider.dart';

final errorServiceProvider = Provider<ErrorService>(
  (ref) => ErrorService(
    loggingService: ref.watch(loggingServiceProvider),
    notices: ref.watch(uiNotificationProvider.notifier),
  ),
);
