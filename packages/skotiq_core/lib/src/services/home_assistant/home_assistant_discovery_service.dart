// Home Assistant auto-discovery coordinator.
//
// When enabled (and the MQTT broker from the notification transport
// settings is configured) this service keeps one persistent MQTT
// session open and:
//   * publishes retained HA discovery configs so the observatory shows
//     up as a single HA device with native entities,
//   * publishes entity state topics on change (2 s debounce tick),
//   * optionally subscribes to command topics (pause/resume/abort)
//     when the user opted in to remote control, routed through the
//     same SequenceExecutor code paths the UI uses.
//
// Availability uses the MQTT last-will: the broker flips the retained
// availability topic to "offline" if the app dies, so HA grays out the
// whole device instead of showing stale state.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../models/notification/transport_configs.dart';
import '../../models/phd2_models.dart';
import '../../models/sequence/sequence_models.dart';
import '../../providers/equipment_provider.dart';
import '../../providers/guiding_provider.dart';
import '../../providers/imaging_provider.dart';
import '../../providers/profiles_provider.dart';
import '../../providers/sequence_provider.dart';
import '../../providers/sequence_stats_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/weather_safety_provider.dart';
import '../notification/transports/mqtt_transport.dart' show MqttSocketOpener;
import '../scheduler/sky_calculations.dart';
import 'ha_discovery_payloads.dart';
import 'ha_mqtt_session_client.dart';
import 'home_assistant_discovery_config.dart';

const _logName = 'HomeAssistantDiscovery';

/// Minimum interval between state publishes (the debounce tick).
const haStatePublishInterval = Duration(seconds: 2);

class HomeAssistantDiscoveryService {
  final Ref _ref;
  final MqttSocketOpener? _opener;

  HomeAssistantDiscoveryConfig _config;
  MqttTransportConfig _broker;

  HaMqttSessionClient? _client;
  HaDiscoveryPayloadBuilder? _payloads;
  Timer? _stateTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _starting = false;
  bool _retryAfterStart = false;

  /// Last published value per state topic, so the tick only publishes
  /// diffs.
  final Map<String, String> _published = {};
  bool? _domeDiscovered;

  HomeAssistantDiscoveryService(
    this._ref, {
    HomeAssistantDiscoveryConfig config = const HomeAssistantDiscoveryConfig(),
    MqttTransportConfig broker = const MqttTransportConfig(),
    MqttSocketOpener? opener,
  }) : _config = config,
       _broker = broker,
       _opener = opener;

  bool get isRunning => _client?.isConnected ?? false;

  bool get _shouldRun =>
      !_disposed && _config.enabled && _broker.host.isNotEmpty;

  void updateConfig(HomeAssistantDiscoveryConfig config) {
    if (config == _config) return;
    _config = config;
    unawaited(_restart());
  }

  void updateBroker(MqttTransportConfig broker) {
    if (broker == _broker) return;
    _broker = broker;
    unawaited(_restart());
  }

  Future<void> reconcile() async {
    if (_shouldRun && _client == null) {
      await _start();
    } else if (!_shouldRun && _client != null) {
      await _stop();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _stop();
  }

  // Session lifecycle

  Future<void> _restart() async {
    await _stop();
    await reconcile();
  }

  Future<void> _start() async {
    if (_starting || !_shouldRun) return;
    _starting = true;
    final configAtStart = _config;
    final brokerAtStart = _broker;
    try {
      final payloads = _buildPayloadBuilder();
      final client = HaMqttSessionClient(
        broker: _broker,
        clientId:
            '${_broker.clientId.isEmpty ? 'skotiq' : _broker.clientId}_ha',
        willTopic: payloads.availabilityTopic,
        onMessage: _handleCommand,
        onDisconnected: _scheduleReconnect,
        opener: _opener,
      );
      await client.connect();
      // Settings may have changed while the connect was in flight; bail
      // and let the pending restart (or disposal) win.
      if (_disposed ||
          !_shouldRun ||
          configAtStart != _config ||
          brokerAtStart != _broker) {
        await client.disconnect();
        _retryAfterStart = true;
        return;
      }
      _client = client;
      _payloads = payloads;
      _published.clear();
      _domeDiscovered = null;

      client.publish(payloads.availabilityTopic, 'online', retain: true);
      _publishDiscovery();
      if (_config.allowControl) {
        client.subscribe(payloads.commandTopic(HaEntityKeys.sequencePaused));
        client.subscribe(payloads.commandTopic(HaEntityKeys.abortSequence));
      }
      _publishStates();
      _stateTimer = Timer.periodic(haStatePublishInterval, (_) => _tick());
      developer.log(
        '[HomeAssistant] Discovery active on ${_broker.host}:${_broker.port} '
        'as device "${payloads.deviceName}"',
        name: _logName,
      );
    } catch (e) {
      developer.log(
        '[HomeAssistant] Failed to start discovery session: $e',
        name: _logName,
        level: 900,
        error: e,
      );
      _client = null;
      _scheduleReconnect();
    } finally {
      _starting = false;
      if (_retryAfterStart) {
        _retryAfterStart = false;
        unawaited(reconcile());
      }
    }
  }

  Future<void> _stop() async {
    _stateTimer?.cancel();
    _stateTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final client = _client;
    final payloads = _payloads;
    _client = null;
    if (client != null) {
      try {
        if (client.isConnected && payloads != null) {
          // Graceful goodbye — the LWT only covers ungraceful drops.
          client.publish(payloads.availabilityTopic, 'offline', retain: true);
        }
      } catch (_) {
        /* socket already gone */
      }
      await client.disconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !_shouldRun) return;
    _stateTimer?.cancel();
    _stateTimer = null;
    _client = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 30), () {
      _reconnectTimer = null;
      unawaited(reconcile());
    });
  }

  HaDiscoveryPayloadBuilder _buildPayloadBuilder() {
    final profileName = _ref
        .read(equipmentProfilesProvider)
        .valueOrNull
        ?.activeProfile
        ?.name;
    final deviceName = _config.deviceName.trim().isNotEmpty
        ? _config.deviceName.trim()
        : 'Skotiq Observatory'
              '${profileName == null ? '' : ' $profileName'}';
    // Node id: the distinctive part of the device name ("Skotiq
    // Observatory Backyard" -> "backyard"), so topics stay short.
    final distinct = deviceName
        .replaceFirst('Skotiq Observatory', '')
        .trim();
    return HaDiscoveryPayloadBuilder(
      nodeId: distinct.isEmpty ? 'observatory' : distinct,
      deviceName: deviceName,
      discoveryPrefix: _config.discoveryPrefix.trim().isEmpty
          ? 'homeassistant'
          : _config.discoveryPrefix.trim(),
    );
  }

  // Discovery + state publishing

  bool get _domeConnected =>
      _ref.read(domeStateProvider).connectionState ==
      DeviceConnectionState.connected;

  void _publishDiscovery() {
    final client = _client;
    final payloads = _payloads;
    if (client == null || payloads == null) return;
    final includeDome = _domeConnected;
    final entries = buildHaDiscoveryEntries(
      payloads,
      includeDome: includeDome,
      includeControls: _config.allowControl,
    );
    for (final entry in entries) {
      client.publish(entry.topic, entry.payload, retain: true);
    }
    _domeDiscovered = includeDome;
  }

  void _tick() {
    final client = _client;
    if (client == null || !client.isConnected) return;
    // Dome connect/disconnect changes the entity set — republish the
    // discovery configs so the roof sensor appears/disappears in HA.
    if (_domeConnected != _domeDiscovered) {
      _publishDiscovery();
    }
    _publishStates();
  }

  void _publishStates() {
    final client = _client;
    final payloads = _payloads;
    if (client == null || payloads == null || !client.isConnected) return;
    final snapshot = _computeStates();
    for (final entry in snapshot.entries) {
      final topic = payloads.stateTopic(entry.key);
      if (_published[topic] == entry.value) continue;
      try {
        client.publish(topic, entry.value, retain: true);
        _published[topic] = entry.value;
      } catch (e) {
        developer.log(
          '[HomeAssistant] State publish failed: $e',
          name: _logName,
          level: 900,
        );
        return;
      }
    }
  }

  Map<String, String> _computeStates() {
    final states = <String, String>{};
    String onOff(bool v) => v ? 'ON' : 'OFF';

    // Safety verdict. HA's `safety` device class renders ON as unsafe.
    final safety = _ref.read(weatherSafetyProvider);
    states[HaEntityKeys.safety] = onOff(!safety.isSafe);

    // Sequencer.
    final execState = _ref.read(sequenceExecutionStateProvider);
    final progress = _ref.read(sequenceProgressProvider);
    final sequenceActive =
        execState == SequenceExecutionState.running ||
        execState == SequenceExecutionState.paused;
    states[HaEntityKeys.sequenceRunning] = onOff(sequenceActive);
    states[HaEntityKeys.sequencePaused] = onOff(
      execState == SequenceExecutionState.paused,
    );
    states[HaEntityKeys.currentTarget] =
        (progress.currentTarget == null ||
            progress.currentTarget!.trim().isEmpty)
        ? 'None'
        : progress.currentTarget!.trim();
    states[HaEntityKeys.sequenceProgress] = (progress.progressPercent * 100)
        .clamp(0, 100)
        .toStringAsFixed(1);

    final liveStats = _ref.read(liveSequenceStatsProvider);
    states[HaEntityKeys.framesTonight] = (liveStats?.framesCaptured ?? 0)
        .toString();

    // Last HFR from the most recent session frame that has stats.
    final images = _ref.read(sessionImagesProvider);
    double? lastHfr;
    for (var i = images.length - 1; i >= 0; i--) {
      final hfr = images[i].stats?.hfr;
      if (hfr != null) {
        lastHfr = hfr;
        break;
      }
    }
    if (lastHfr != null) {
      states[HaEntityKeys.lastHfr] = lastHfr.toStringAsFixed(2);
    }

    // Guiding.
    final phd2State = _ref.read(phd2StateProvider);
    states[HaEntityKeys.guiding] = onOff(
      phd2State == Phd2State.guiding || phd2State == Phd2State.settling,
    );
    final guideStats = _ref.read(guideStatsProvider);
    states[HaEntityKeys.guideRms] = guideStats.rmsTotal.toStringAsFixed(2);

    // Camera.
    final camera = _ref.read(cameraStateProvider);
    states[HaEntityKeys.cameraCooling] = onOff(camera.isCooling);
    if (camera.temperature != null) {
      states[HaEntityKeys.cameraTemperature] = camera.temperature!
          .toStringAsFixed(1);
    }

    // Roof/dome — only meaningful when a dome is connected (the
    // discovery config is removed otherwise).
    final dome = _ref.read(domeStateProvider);
    if (dome.connectionState == DeviceConnectionState.connected) {
      states[HaEntityKeys.roofOpen] = onOff(
        dome.shutterStatus == ShutterStatus.open ||
            dome.shutterStatus == ShutterStatus.opening,
      );
    }

    // Weather device values (publish only what the device reports).
    final weather = _ref.read(weatherStateProvider);
    void addIfPresent(String key, double? value, [int digits = 1]) {
      if (value != null) states[key] = value.toStringAsFixed(digits);
    }

    addIfPresent(HaEntityKeys.ambientTemperature, weather.temperature);
    addIfPresent(HaEntityKeys.humidity, weather.humidity, 0);
    addIfPresent(HaEntityKeys.dewPoint, weather.dewPoint);
    addIfPresent(HaEntityKeys.windSpeed, weather.windSpeedKph);
    addIfPresent(HaEntityKeys.cloudCover, weather.cloudCover, 0);
    addIfPresent(HaEntityKeys.skyTemperature, weather.skyTemperature);

    // Sun altitude from the configured site. Rounded to 0.1° so the
    // retained topic only updates when the value meaningfully moves.
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings != null) {
      final (altitude, _) = SkyCalculations.sunAltAz(
        time: DateTime.now().toUtc(),
        latitudeDegrees: settings.latitude,
        longitudeDegrees: settings.longitude,
      );
      states[HaEntityKeys.sunAltitude] = altitude.toStringAsFixed(1);
    }

    return states;
  }

  // Commands from Home Assistant

  void _handleCommand(String topic, String payload) {
    final payloads = _payloads;
    if (payloads == null) return;
    if (!_config.allowControl) {
      // Race guard: a retained/in-flight command arriving right after
      // the user revoked control must not act.
      return;
    }
    if (topic == payloads.commandTopic(HaEntityKeys.sequencePaused)) {
      final wantPause = payload.trim().toUpperCase() == 'ON';
      unawaited(
        _runSequencerCommand(wantPause ? 'pause' : 'resume', () {
          final executor = _ref.read(sequenceExecutorProvider);
          return wantPause ? executor.pause() : executor.resume();
        }),
      );
    } else if (topic == payloads.commandTopic(HaEntityKeys.abortSequence)) {
      unawaited(
        _runSequencerCommand('abort', () {
          // Mirror the UI Stop button: keep the checkpoint so the operator
          // can resume later (see SequenceExecutor.stop docs).
          return _ref
              .read(sequenceExecutorProvider)
              .stop(preserveCheckpoint: true);
        }),
      );
    }
  }

  Future<void> _runSequencerCommand(
    String label,
    Future<void> Function() action,
  ) async {
    developer.log('[HomeAssistant] Command from HA: $label', name: _logName);
    try {
      await action();
    } catch (e) {
      // Executor throws on invalid transitions (e.g. pause while idle);
      // log it and let the next state tick republish the truth so the
      // HA switch snaps back.
      developer.log(
        '[HomeAssistant] Command "$label" rejected: $e',
        name: _logName,
        level: 900,
      );
    } finally {
      _publishStates();
    }
  }
}
