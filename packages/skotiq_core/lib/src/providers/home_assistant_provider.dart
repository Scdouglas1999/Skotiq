// Riverpod wiring for Home Assistant MQTT auto-discovery.
//
// Storage: one key-value `SettingsDao` blob (`home_assistant_discovery`)
// holding [HomeAssistantDiscoveryConfig.toJson]. No secrets live here —
// the broker credentials are owned by the MQTT notification transport
// config (`mqttTransportConfigProvider`), which this feature reuses so
// the broker is configured exactly once.
//
// The service provider must be eager-read at app start (same as
// `notificationRouterProvider`) so discovery runs without any UI
// surface depending on it.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/host_mutation_event.dart';
import '../models/notification/transport_configs.dart';
import '../services/home_assistant/home_assistant_discovery_config.dart';
import '../services/home_assistant/home_assistant_discovery_service.dart';
import '../services/home_assistant/home_assistant_host_settings.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import '../settings/store_settings.dart';
import 'database_provider.dart';
import 'notification_router_provider.dart';
import '../database/daos/settings_dao.dart';

class HomeAssistantConfigNotifier
    extends AsyncNotifier<HomeAssistantDiscoveryConfig> {
  @override
  Future<HomeAssistantDiscoveryConfig> build() async {
    final dao = ref.read(settingsDaoProvider);
    final raw = await dao.read(StoreSettings.homeAssistantDiscovery);
    if (raw == null) return const HomeAssistantDiscoveryConfig();
    try {
      return HomeAssistantDiscoveryConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      developer.log(
        '[HomeAssistantProviders] Bad config blob: $e',
        name: 'HomeAssistantProviders',
        level: 900,
      );
      return const HomeAssistantDiscoveryConfig();
    }
  }

  Future<void> save(HomeAssistantDiscoveryConfig config) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.write(
      StoreSettings.homeAssistantDiscovery,
      jsonEncode(config.toJson()),
    );
    state = AsyncData(config);
  }
}

final homeAssistantConfigProvider =
    AsyncNotifierProvider<
      HomeAssistantConfigNotifier,
      HomeAssistantDiscoveryConfig
    >(HomeAssistantConfigNotifier.new);

/// Imaging-host Home Assistant snapshot for remote settings screens.
///
/// Local desktop callers continue to use [homeAssistantConfigProvider] and
/// [mqttTransportConfigProvider] directly. Keeping this provider remote-only
/// preserves the intentional per-device notification-router configuration.
final remoteHomeAssistantHostSettingsProvider =
    FutureProvider.autoDispose<HomeAssistantHostSettings?>((ref) async {
      final backend = ref.watch(backendProvider);
      final remote = backend.remoteHost?.rigSettings;
      if (remote == null) return null;
      final subscription = backend.eventStream.listen((event) {
        if (event.eventType == hostStateChangedEventType &&
            event.data['entityType'] == HostMutationEntity.settings &&
            event.data['namespace'] == 'home-assistant') {
          ref.invalidateSelf();
        }
      });
      ref.onDispose(subscription.cancel);
      return remote.getHomeAssistantHostSettings();
    });

/// The discovery service singleton. Config changes (this feature's own
/// settings and the shared MQTT broker settings) are forwarded in-place
/// so a settings toggle restarts the MQTT session without tearing the
/// provider down.
final homeAssistantDiscoveryProvider = Provider<HomeAssistantDiscoveryService>((
  ref,
) {
  final service = HomeAssistantDiscoveryService(
    ref,
    config:
        ref.read(homeAssistantConfigProvider).valueOrNull ??
        const HomeAssistantDiscoveryConfig(),
    broker:
        ref.read(mqttTransportConfigProvider).valueOrNull ??
        const MqttTransportConfig(),
  );

  ref.listen(homeAssistantConfigProvider, (prev, next) {
    next.whenData(service.updateConfig);
  });
  ref.listen(mqttTransportConfigProvider, (prev, next) {
    next.whenData(service.updateBroker);
  });

  // The synchronous reads above usually see the pre-DB defaults; once
  // the persisted blobs arrive the listeners reconcile. Still kick a
  // reconcile for the (test/replay) case where values were already
  // resolved.
  unawaited(service.reconcile());

  ref.onDispose(() {
    unawaited(service.dispose());
  });

  return service;
});
