import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database_provider.dart';
import '../darkroom_delivery/delivery_providers.dart';
import '../../services/darkroom_autopilot/guided_build_delivery.dart';
import '../logging_service_provider.dart';
import '../notification_service_provider.dart';

final guidedBuildDeliveryProvider = Provider<GuidedBuildDelivery>((ref) {
  return GuidedBuildDelivery(
    jobs: ref.watch(darkroomJobsDaoProvider),
    delivery: ref.watch(deliveryServiceProvider),
    notifications: ref.watch(notificationServiceProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});
