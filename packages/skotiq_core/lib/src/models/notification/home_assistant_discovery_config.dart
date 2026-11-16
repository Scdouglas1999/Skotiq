// User-facing configuration for Home Assistant MQTT auto-discovery.
//
// Broker connection details deliberately live in [MqttTransportConfig]
// (the notification transport's broker settings) — this config only
// covers the discovery feature itself, so the user configures the
// broker exactly once.

import 'package:equatable/equatable.dart';

class HomeAssistantDiscoveryConfig extends Equatable {
  /// Master opt-in. Default OFF: nothing is published until the user
  /// explicitly enables discovery.
  final bool enabled;

  /// Device name override shown in HA. When empty, the service derives
  /// "Skotiq Observatory `<active profile name>`".
  final String deviceName;

  /// Allow HA to pause/resume/abort the running sequence. Default OFF.
  final bool allowControl;

  /// HA discovery prefix; `homeassistant` unless the user relocated it.
  final String discoveryPrefix;

  const HomeAssistantDiscoveryConfig({
    this.enabled = false,
    this.deviceName = '',
    this.allowControl = false,
    this.discoveryPrefix = 'homeassistant',
  });

  HomeAssistantDiscoveryConfig copyWith({
    bool? enabled,
    String? deviceName,
    bool? allowControl,
    String? discoveryPrefix,
  }) => HomeAssistantDiscoveryConfig(
    enabled: enabled ?? this.enabled,
    deviceName: deviceName ?? this.deviceName,
    allowControl: allowControl ?? this.allowControl,
    discoveryPrefix: discoveryPrefix ?? this.discoveryPrefix,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'deviceName': deviceName,
    'allowControl': allowControl,
    'discoveryPrefix': discoveryPrefix,
  };

  factory HomeAssistantDiscoveryConfig.fromJson(Map<String, dynamic> json) =>
      HomeAssistantDiscoveryConfig(
        enabled: json['enabled'] as bool? ?? false,
        deviceName: json['deviceName'] as String? ?? '',
        allowControl: json['allowControl'] as bool? ?? false,
        discoveryPrefix: json['discoveryPrefix'] as String? ?? 'homeassistant',
      );

  @override
  List<Object?> get props => [
    enabled,
    deviceName,
    allowControl,
    discoveryPrefix,
  ];
}
