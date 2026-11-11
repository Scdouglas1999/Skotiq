import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PushDeliveryTargets;

/// Notification delivery configured on a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostNotifications {
  Future<HomeAssistantHostSettings> updateHomeAssistantHostSettings({
    required HomeAssistantDiscoveryConfig config,
    required MqttTransportConfig broker,
    String? replacementPassword,
    bool replacePassword = false,
  });

  Future<PushDeliveryTargets> getPushDeliveryTargets();

  Stream<Map<String, dynamic>> get pushNotificationStream;
}
