// Home Assistant MQTT discovery payload generation.
//
// Pure functions/classes only — no sockets, no Riverpod — so the JSON
// shape, topic naming, and slug rules are unit-testable in isolation.
// The wire format follows the HA MQTT discovery contract:
//   <prefix>/<component>/<node_id>/<object_id>/config   (retained)
// with entity state on plain `skotiq/<node_id>/...` topics.
//
// Reference: https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery

import 'dart:convert';

/// Sanitizes [input] into an HA-safe slug: lowercase `[a-z0-9_]`,
/// runs of other characters collapsed to single underscores, no
/// leading/trailing underscore. Falls back to `skotiq` when the
/// input contains nothing usable.
String haSlugify(String input) {
  final lowered = input.toLowerCase();
  final buffer = StringBuffer();
  var lastWasUnderscore = true; // suppress leading underscore
  for (final rune in lowered.runes) {
    final ch = String.fromCharCode(rune);
    final isValid =
        (ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7a) ||
        (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39);
    if (isValid) {
      buffer.write(ch);
      lastWasUnderscore = false;
    } else if (!lastWasUnderscore) {
      buffer.write('_');
      lastWasUnderscore = true;
    }
  }
  var slug = buffer.toString();
  while (slug.endsWith('_')) {
    slug = slug.substring(0, slug.length - 1);
  }
  return slug.isEmpty ? 'skotiq' : slug;
}

/// Builds discovery config payloads + topic names for one Skotiq
/// observatory device.
class HaDiscoveryPayloadBuilder {
  /// Slug identifying this observatory, e.g. `backyard_rig`.
  final String nodeId;

  /// Human-readable HA device name, e.g. `Skotiq Observatory Backyard`.
  final String deviceName;

  /// HA discovery prefix; `homeassistant` unless the user moved it.
  final String discoveryPrefix;

  /// Optional software version surfaced on the HA device page.
  final String? swVersion;

  HaDiscoveryPayloadBuilder({
    required String nodeId,
    required this.deviceName,
    this.discoveryPrefix = 'homeassistant',
    this.swVersion,
  }) : nodeId = haSlugify(nodeId);

  String get _deviceId => 'skotiq_$nodeId';

  /// Single availability topic shared by every entity; also used as the
  /// MQTT last-will topic so HA marks everything unavailable if the app
  /// dies without a clean disconnect.
  String get availabilityTopic => 'skotiq/$nodeId/availability';

  String stateTopic(String key) => 'skotiq/$nodeId/$key/state';

  String commandTopic(String key) => 'skotiq/$nodeId/$key/set';

  String configTopic(String component, String key) =>
      '$discoveryPrefix/$component/$_deviceId/$key/config';

  /// The `device` block that groups all entities under one HA device.
  Map<String, dynamic> get deviceBlock => {
    'identifiers': [_deviceId],
    'name': deviceName,
    'manufacturer': 'Skotiq',
    'model': 'Skotiq Observatory',
    if (swVersion != null) 'sw_version': swVersion,
  };

  Map<String, dynamic> _base(String key, String name) => {
    'name': name,
    'unique_id': '${_deviceId}_$key',
    'availability_topic': availabilityTopic,
    'payload_available': 'online',
    'payload_not_available': 'offline',
    'device': deviceBlock,
  };

  Map<String, dynamic> binarySensorConfig({
    required String key,
    required String name,
    String? deviceClass,
    String? icon,
  }) => {
    ..._base(key, name),
    'state_topic': stateTopic(key),
    'payload_on': 'ON',
    'payload_off': 'OFF',
    if (deviceClass != null) 'device_class': deviceClass,
    if (icon != null) 'icon': icon,
  };

  Map<String, dynamic> sensorConfig({
    required String key,
    required String name,
    String? unit,
    String? deviceClass,
    String? stateClass,
    String? icon,
  }) => {
    ..._base(key, name),
    'state_topic': stateTopic(key),
    if (unit != null) 'unit_of_measurement': unit,
    if (deviceClass != null) 'device_class': deviceClass,
    if (stateClass != null) 'state_class': stateClass,
    if (icon != null) 'icon': icon,
  };

  Map<String, dynamic> switchConfig({
    required String key,
    required String name,
    String? icon,
  }) => {
    ..._base(key, name),
    'state_topic': stateTopic(key),
    'command_topic': commandTopic(key),
    'payload_on': 'ON',
    'payload_off': 'OFF',
    if (icon != null) 'icon': icon,
  };

  Map<String, dynamic> buttonConfig({
    required String key,
    required String name,
    String? icon,
  }) => {
    ..._base(key, name),
    'command_topic': commandTopic(key),
    'payload_press': 'PRESS',
    if (icon != null) 'icon': icon,
  };
}

/// One discovery entry: where to publish (`topic`) and what (`payload`,
/// already JSON-encoded; empty string = "delete this entity" per the HA
/// retained-config contract).
class HaDiscoveryEntry {
  final String topic;
  final String payload;
  const HaDiscoveryEntry(this.topic, this.payload);
}

/// Entity keys, kept in one place so the discovery set and the state
/// publisher cannot drift apart.
abstract final class HaEntityKeys {
  // Binary sensors
  static const safety = 'safety';
  static const sequenceRunning = 'sequence_running';
  static const guiding = 'guiding';
  static const roofOpen = 'roof_open';
  static const cameraCooling = 'camera_cooling';

  // Sensors
  static const currentTarget = 'current_target';
  static const sequenceProgress = 'sequence_progress';
  static const framesTonight = 'frames_tonight';
  static const lastHfr = 'last_hfr';
  static const guideRms = 'guide_rms';
  static const cameraTemperature = 'camera_temperature';
  static const ambientTemperature = 'ambient_temperature';
  static const humidity = 'humidity';
  static const dewPoint = 'dew_point';
  static const windSpeed = 'wind_speed';
  static const cloudCover = 'cloud_cover';
  static const skyTemperature = 'sky_temperature';
  static const sunAltitude = 'sun_altitude';

  // Commands (gated behind allow-control)
  static const sequencePaused = 'sequence_paused';
  static const abortSequence = 'abort_sequence';
}

/// Builds the full retained discovery set for the observatory.
///
/// [includeDome] adds the roof/dome binary sensor (only when a dome is
/// actually connected — HA should not show a roof for rigs without one).
/// [includeControls] adds the pause switch + abort button; OFF by
/// default and gated behind the "allow control from Home Assistant"
/// setting.
List<HaDiscoveryEntry> buildHaDiscoveryEntries(
  HaDiscoveryPayloadBuilder b, {
  required bool includeDome,
  required bool includeControls,
}) {
  String enc(Map<String, dynamic> m) => jsonEncode(m);

  final entries = <HaDiscoveryEntry>[
    // Binary sensors
    HaDiscoveryEntry(
      b.configTopic('binary_sensor', HaEntityKeys.safety),
      // HA `safety` device class: ON = unsafe.
      enc(
        b.binarySensorConfig(
          key: HaEntityKeys.safety,
          name: 'Safety',
          deviceClass: 'safety',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('binary_sensor', HaEntityKeys.sequenceRunning),
      enc(
        b.binarySensorConfig(
          key: HaEntityKeys.sequenceRunning,
          name: 'Sequence Running',
          deviceClass: 'running',
          icon: 'mdi:play-circle',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('binary_sensor', HaEntityKeys.guiding),
      enc(
        b.binarySensorConfig(
          key: HaEntityKeys.guiding,
          name: 'Guiding Active',
          deviceClass: 'running',
          icon: 'mdi:crosshairs-gps',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('binary_sensor', HaEntityKeys.roofOpen),
      includeDome
          ? enc(
              b.binarySensorConfig(
                key: HaEntityKeys.roofOpen,
                name: 'Roof Open',
                deviceClass: 'door',
                icon: 'mdi:garage-open',
              ),
            )
          // Empty retained payload removes a previously-discovered entity.
          : '',
    ),
    HaDiscoveryEntry(
      b.configTopic('binary_sensor', HaEntityKeys.cameraCooling),
      enc(
        b.binarySensorConfig(
          key: HaEntityKeys.cameraCooling,
          name: 'Camera Cooling',
          deviceClass: 'running',
          icon: 'mdi:snowflake',
        ),
      ),
    ),

    // Sensors
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.currentTarget),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.currentTarget,
          name: 'Current Target',
          icon: 'mdi:telescope',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.sequenceProgress),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.sequenceProgress,
          name: 'Sequence Progress',
          unit: '%',
          stateClass: 'measurement',
          icon: 'mdi:progress-clock',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.framesTonight),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.framesTonight,
          name: 'Frames Captured Tonight',
          stateClass: 'measurement',
          icon: 'mdi:image-multiple',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.lastHfr),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.lastHfr,
          name: 'Last HFR',
          unit: 'px',
          stateClass: 'measurement',
          icon: 'mdi:image-filter-center-focus',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.guideRms),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.guideRms,
          name: 'Guide RMS',
          unit: '″',
          stateClass: 'measurement',
          icon: 'mdi:chart-line-variant',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.cameraTemperature),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.cameraTemperature,
          name: 'Camera Temperature',
          unit: '°C',
          deviceClass: 'temperature',
          stateClass: 'measurement',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.ambientTemperature),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.ambientTemperature,
          name: 'Ambient Temperature',
          unit: '°C',
          deviceClass: 'temperature',
          stateClass: 'measurement',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.humidity),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.humidity,
          name: 'Humidity',
          unit: '%',
          deviceClass: 'humidity',
          stateClass: 'measurement',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.dewPoint),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.dewPoint,
          name: 'Dew Point',
          unit: '°C',
          deviceClass: 'temperature',
          stateClass: 'measurement',
          icon: 'mdi:water-thermometer',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.windSpeed),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.windSpeed,
          name: 'Wind Speed',
          unit: 'km/h',
          deviceClass: 'wind_speed',
          stateClass: 'measurement',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.cloudCover),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.cloudCover,
          name: 'Cloud Cover',
          unit: '%',
          stateClass: 'measurement',
          icon: 'mdi:cloud-percent',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.skyTemperature),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.skyTemperature,
          name: 'Sky Temperature',
          unit: '°C',
          deviceClass: 'temperature',
          stateClass: 'measurement',
          icon: 'mdi:weather-night',
        ),
      ),
    ),
    HaDiscoveryEntry(
      b.configTopic('sensor', HaEntityKeys.sunAltitude),
      enc(
        b.sensorConfig(
          key: HaEntityKeys.sunAltitude,
          name: 'Sun Altitude',
          unit: '°',
          stateClass: 'measurement',
          icon: 'mdi:weather-sunset',
        ),
      ),
    ),

    // Commands
    HaDiscoveryEntry(
      b.configTopic('switch', HaEntityKeys.sequencePaused),
      includeControls
          ? enc(
              b.switchConfig(
                key: HaEntityKeys.sequencePaused,
                name: 'Sequence Paused',
                icon: 'mdi:pause-circle',
              ),
            )
          : '',
    ),
    HaDiscoveryEntry(
      b.configTopic('button', HaEntityKeys.abortSequence),
      includeControls
          ? enc(
              b.buttonConfig(
                key: HaEntityKeys.abortSequence,
                name: 'Abort Sequence',
                icon: 'mdi:stop-circle',
              ),
            )
          : '',
    ),
  ];

  return entries;
}
