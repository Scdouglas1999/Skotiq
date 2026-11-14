import '../../models/notification/transport_configs.dart';
import 'home_assistant_discovery_config.dart';

/// Sanitized host-owned Home Assistant configuration shown to a remote
/// controller. Broker passwords never cross back to the client; only their
/// presence is disclosed so the UI can offer an explicit replacement field.
class HomeAssistantHostSettings {
  final HomeAssistantDiscoveryConfig config;
  final MqttTransportConfig broker;
  final bool brokerPasswordConfigured;

  const HomeAssistantHostSettings({
    required this.config,
    required this.broker,
    required this.brokerPasswordConfigured,
  });

  factory HomeAssistantHostSettings.fromJson(Map<String, dynamic> json) {
    final configJson = json['config'];
    final brokerJson = json['broker'];
    if (configJson is! Map<String, dynamic> ||
        brokerJson is! Map<String, dynamic>) {
      throw const FormatException(
        'Malformed Home Assistant host settings response',
      );
    }
    return HomeAssistantHostSettings(
      config: HomeAssistantDiscoveryConfig.fromJson(configJson),
      broker: MqttTransportConfig.fromJson(
        brokerJson,
      ).copyWith(clearPassword: true),
      brokerPasswordConfigured:
          json['brokerPasswordConfigured'] as bool? ?? false,
    );
  }
}
