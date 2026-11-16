part of '../network_backend.dart';

/// Notification delivery configured on a linked imaging host.
mixin HostNotifications on NetworkBackendTransport {
  /// Replace the host's Home Assistant discovery and broker configuration.
  ///
  /// Omitting [replacementPassword] preserves the write-only host secret;
  /// passing an empty string explicitly clears it.
  Future<HomeAssistantHostSettings> updateHomeAssistantHostSettings({
    required HomeAssistantDiscoveryConfig config,
    required MqttTransportConfig broker,
    String? replacementPassword,
    bool replacePassword = false,
  }) async {
    final response = await _post(
      ProfileApi.updateHomeAssistantSettings,
      body: {
        'config': config.toJson(),
        'broker': broker.copyWith(clearPassword: true).toJson(),
        if (replacePassword) 'password': replacementPassword ?? '',
      },
    );
    return HomeAssistantHostSettings.fromJson(response);
  }

  /// GET /api/push/targets — whether a critical alert could actually reach a
  /// phone right now (registered push tokens + a configured delivery channel).
  ///
  /// Counts and a verdict only; the host never returns token values.
  Future<PushDeliveryTargets> getPushDeliveryTargets() async {
    final response = await _get(PushApi.getTargets);
    return PushDeliveryTargets.fromJson(response);
  }
}
