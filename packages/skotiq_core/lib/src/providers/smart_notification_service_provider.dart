import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/smart_notification_service.dart';

final smartNotificationServiceProvider = Provider<SmartNotificationService>((
  ref,
) {
  return SmartNotificationService(ref);
});
