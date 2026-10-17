import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/home_assistant/ha_discovery_payloads.dart';

void main() {
  group('haSlugify', () {
    test('lowercases and keeps alphanumerics', () {
      expect(haSlugify('Backyard1'), 'backyard1');
    });

    test('collapses runs of invalid characters to single underscores', () {
      expect(haSlugify('My  Roll-Off Roof!'), 'my_roll_off_roof');
      expect(haSlugify('Obs — North (2)'), 'obs_north_2');
    });

    test('strips leading and trailing underscores', () {
      expect(haSlugify('  padded  '), 'padded');
      expect(haSlugify('--dash--'), 'dash');
    });

    test('falls back to skotiq when nothing usable remains', () {
      expect(haSlugify('***'), 'skotiq');
      expect(haSlugify(''), 'skotiq');
    });
  });

  group('HaDiscoveryPayloadBuilder topics', () {
    final b = HaDiscoveryPayloadBuilder(
      nodeId: 'Backyard Rig',
      deviceName: 'Skotiq Observatory Backyard Rig',
    );

    test('node id is slugified by the constructor', () {
      expect(b.nodeId, 'backyard_rig');
    });

    test('availability topic', () {
      expect(b.availabilityTopic, 'skotiq/backyard_rig/availability');
    });

    test('state and command topics', () {
      expect(b.stateTopic('guiding'), 'skotiq/backyard_rig/guiding/state');
      expect(
        b.commandTopic('sequence_paused'),
        'skotiq/backyard_rig/sequence_paused/set',
      );
    });

    test('config topic follows the HA discovery contract', () {
      expect(
        b.configTopic('binary_sensor', 'safety'),
        'homeassistant/binary_sensor/skotiq_backyard_rig/safety/config',
      );
    });

    test('custom discovery prefix is honoured', () {
      final custom = HaDiscoveryPayloadBuilder(
        nodeId: 'obs',
        deviceName: 'Obs',
        discoveryPrefix: 'ha_disc',
      );
      expect(
        custom.configTopic('sensor', 'last_hfr'),
        'ha_disc/sensor/skotiq_obs/last_hfr/config',
      );
    });
  });

  group('discovery config JSON shape', () {
    final b = HaDiscoveryPayloadBuilder(
      nodeId: 'obs',
      deviceName: 'Skotiq Observatory Obs',
      swVersion: '4.0.0',
    );

    test('binary sensor payload carries state topic, payloads, device', () {
      final cfg = b.binarySensorConfig(
        key: 'sequence_running',
        name: 'Sequence Running',
        deviceClass: 'running',
      );
      expect(cfg['name'], 'Sequence Running');
      expect(cfg['unique_id'], 'skotiq_obs_sequence_running');
      expect(cfg['state_topic'], 'skotiq/obs/sequence_running/state');
      expect(cfg['payload_on'], 'ON');
      expect(cfg['payload_off'], 'OFF');
      expect(cfg['device_class'], 'running');
      expect(cfg['availability_topic'], 'skotiq/obs/availability');
      expect(cfg['payload_available'], 'online');
      expect(cfg['payload_not_available'], 'offline');
    });

    test('device block groups every entity under one HA device', () {
      final device = b.deviceBlock;
      expect(device['identifiers'], ['skotiq_obs']);
      expect(device['name'], 'Skotiq Observatory Obs');
      expect(device['manufacturer'], 'Skotiq');
      expect(device['model'], 'Skotiq Observatory');
      expect(device['sw_version'], '4.0.0');

      final sensor = b.sensorConfig(key: 'guide_rms', name: 'Guide RMS');
      expect(sensor['device'], device);
    });

    test('sensor payload includes unit/device_class/state_class when set', () {
      final cfg = b.sensorConfig(
        key: 'camera_temperature',
        name: 'Camera Temperature',
        unit: '°C',
        deviceClass: 'temperature',
        stateClass: 'measurement',
      );
      expect(cfg['unit_of_measurement'], '°C');
      expect(cfg['device_class'], 'temperature');
      expect(cfg['state_class'], 'measurement');
      // Optional keys are omitted, not nulled.
      final bare = b.sensorConfig(key: 'current_target', name: 'Target');
      expect(bare.containsKey('unit_of_measurement'), isFalse);
      expect(bare.containsKey('device_class'), isFalse);
    });

    test('switch payload has both state and command topics', () {
      final cfg = b.switchConfig(key: 'sequence_paused', name: 'Paused');
      expect(cfg['state_topic'], 'skotiq/obs/sequence_paused/state');
      expect(cfg['command_topic'], 'skotiq/obs/sequence_paused/set');
      expect(cfg['payload_on'], 'ON');
      expect(cfg['payload_off'], 'OFF');
    });

    test('button payload has a command topic and no state topic', () {
      final cfg = b.buttonConfig(key: 'abort_sequence', name: 'Abort');
      expect(cfg['command_topic'], 'skotiq/obs/abort_sequence/set');
      expect(cfg['payload_press'], 'PRESS');
      expect(cfg.containsKey('state_topic'), isFalse);
    });
  });

  group('buildHaDiscoveryEntries', () {
    final b = HaDiscoveryPayloadBuilder(nodeId: 'obs', deviceName: 'Obs');

    Map<String, String> byTopic(List<HaDiscoveryEntry> entries) => {
      for (final e in entries) e.topic: e.payload,
    };

    test('full set: every payload is valid JSON sharing the device block', () {
      final entries = buildHaDiscoveryEntries(
        b,
        includeDome: true,
        includeControls: true,
      );
      expect(entries, isNotEmpty);
      for (final entry in entries) {
        expect(
          entry.payload,
          isNotEmpty,
          reason: '${entry.topic} should be present in the full set',
        );
        final decoded = jsonDecode(entry.payload) as Map<String, dynamic>;
        expect(
          decoded['device'],
          b.deviceBlock,
          reason: '${entry.topic} must group under the shared device',
        );
        expect(decoded['unique_id'], startsWith('skotiq_obs_'));
        expect(decoded['availability_topic'], b.availabilityTopic);
      }
    });

    test('expected entities are present with the right components', () {
      final topics = byTopic(
        buildHaDiscoveryEntries(b, includeDome: true, includeControls: true),
      ).keys.toSet();
      expect(
        topics,
        containsAll([
          'homeassistant/binary_sensor/skotiq_obs/safety/config',
          'homeassistant/binary_sensor/skotiq_obs/sequence_running/config',
          'homeassistant/binary_sensor/skotiq_obs/guiding/config',
          'homeassistant/binary_sensor/skotiq_obs/roof_open/config',
          'homeassistant/binary_sensor/skotiq_obs/camera_cooling/config',
          'homeassistant/sensor/skotiq_obs/current_target/config',
          'homeassistant/sensor/skotiq_obs/sequence_progress/config',
          'homeassistant/sensor/skotiq_obs/frames_tonight/config',
          'homeassistant/sensor/skotiq_obs/last_hfr/config',
          'homeassistant/sensor/skotiq_obs/guide_rms/config',
          'homeassistant/sensor/skotiq_obs/camera_temperature/config',
          'homeassistant/sensor/skotiq_obs/ambient_temperature/config',
          'homeassistant/sensor/skotiq_obs/humidity/config',
          'homeassistant/sensor/skotiq_obs/sun_altitude/config',
          'homeassistant/switch/skotiq_obs/sequence_paused/config',
          'homeassistant/button/skotiq_obs/abort_sequence/config',
        ]),
      );
    });

    test('no dome -> roof config is an empty retained delete payload', () {
      final topics = byTopic(
        buildHaDiscoveryEntries(b, includeDome: false, includeControls: true),
      );
      expect(
        topics['homeassistant/binary_sensor/skotiq_obs/roof_open/config'],
        isEmpty,
      );
    });

    test('controls disabled -> switch/button configs are delete payloads', () {
      final topics = byTopic(
        buildHaDiscoveryEntries(b, includeDome: true, includeControls: false),
      );
      expect(
        topics['homeassistant/switch/skotiq_obs/sequence_paused/config'],
        isEmpty,
      );
      expect(
        topics['homeassistant/button/skotiq_obs/abort_sequence/config'],
        isEmpty,
      );
      // Read-only sensors stay published.
      expect(
        topics['homeassistant/sensor/skotiq_obs/current_target/config'],
        isNotEmpty,
      );
    });

    test('safety binary sensor uses HA safety device class (ON = unsafe)', () {
      final topics = byTopic(
        buildHaDiscoveryEntries(b, includeDome: false, includeControls: false),
      );
      final safety =
          jsonDecode(
                topics['homeassistant/binary_sensor/skotiq_obs/safety/config']!,
              )
              as Map<String, dynamic>;
      expect(safety['device_class'], 'safety');
    });
  });
}
