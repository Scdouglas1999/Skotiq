// Which events a linked client's narrator feed leaves out of its re-fetch
// as per-tick telemetry. One row per event over both transports, plus the
// events that never decode (host-made, sync, job). Pinned on the name set.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/providers/remote_snapshot_stream.dart';

import '../harness/event_wire.dart';

bool _narratorSkips(SkotiqEvent event) => isHostTelemetryEvent(event);

typedef _E = bridge.EquipmentEvent;
typedef _I = bridge.ImagingEvent;
typedef _G = bridge.GuidingEvent;
typedef _S = bridge.SequencerEvent;

/// The per-tick events and their neighbors.
final Map<String, bridge.EventPayload> _rows = {
  'imaging exposureProgress': const bridge.EventPayload.imaging(
    _I.exposureProgress(progress: 0.5, remainingSecs: 15),
  ),
  'imaging exposureStarted': const bridge.EventPayload.imaging(
    _I.exposureStarted(durationSecs: 30, frameType: bridge.FrameType.light),
  ),
  'imaging temperatureChanged': const bridge.EventPayload.imaging(
    _I.temperatureChanged(tempCelsius: -10, coolerPower: 30),
  ),
  'imaging integrationProgress': const bridge.EventPayload.imaging(
    _I.integrationProgress(phase: 'registering', fraction: 0.25),
  ),
  'imaging imageSaved': const bridge.EventPayload.imaging(
    _I.imageSaved(filePath: '/f.fits'),
  ),
  'guiding correction': const bridge.EventPayload.guiding(
    _G.correction(ra: 0.2, dec: -0.1, raRaw: 0.2, decRaw: -0.1),
  ),
  'guiding guideStats': const bridge.EventPayload.guiding(
    _G.guideStats(snr: 20, starMass: 3000),
  ),
  'guiding guidingStarted': const bridge.EventPayload.guiding(
    _G.guidingStarted(),
  ),
  'equipment cameraTemperatureChanged': const bridge.EventPayload.equipment(
    _E.cameraTemperatureChanged(
      deviceId: 'cam',
      temperature: -10,
      coolerPower: 30,
    ),
  ),
  'equipment AutofocusProgress': const bridge.EventPayload.equipment(
    _E.propertyChanged(
      deviceType: 'focuser',
      deviceId: 'foc',
      property: 'AutofocusProgress',
      value: '{}',
    ),
  ),
  'equipment Gain': const bridge.EventPayload.equipment(
    _E.propertyChanged(
      deviceType: 'camera',
      deviceId: 'cam',
      property: 'Gain',
      value: '100',
    ),
  ),
  'equipment connected': const bridge.EventPayload.equipment(
    _E.connected(deviceType: 'camera', deviceId: 'cam', deviceName: 'Cam'),
  ),
  'sequencer instructionProgress': const bridge.EventPayload.sequencer(
    _S.instructionProgress(
      nodeId: 'n1',
      instruction: 'TakeExposure',
      progressPercent: 10,
      detail: '',
      detailKind: '',
      detailJson: '',
    ),
  ),
  'sequencer progress': const bridge.EventPayload.sequencer(
    _S.progress(current: 1, total: 4),
  ),
  'sequencer ditherPerformed': const bridge.EventPayload.sequencer(
    _S.ditherPerformed(nodeId: 'n1'),
  ),
  'sequencer frameWatchReport': const bridge.EventPayload.sequencer(
    _S.frameWatchReport(kind: 'frame_assessed', payloadJson: '{}'),
  ),
  'sequencer completed': const bridge.EventPayload.sequencer(_S.completed()),
};

void main() {
  test('the events the narrator feed does not re-fetch for', () {
    final table = <String, bool>{};
    for (final row in _rows.entries) {
      final ffi = _narratorSkips(ffiWireEvent(row.value));
      expect(_narratorSkips(networkWireEvent(row.value)), ffi, reason: row.key);
      table[row.key] = ffi;
    }
    table['wire settingsChanged'] = _narratorSkips(
      unsentWireEvent(EventCategory.system, settingsChangedEventType),
    );
    table['wire JobProgress'] = _narratorSkips(
      unsentWireEvent(EventCategory.job, 'JobProgress'),
    );
    table['wire MountPositionChanged'] = _narratorSkips(
      unsentWireEvent(EventCategory.equipment, 'MountPositionChanged'),
    );
    expect(table, <String, bool>{
      'imaging exposureProgress': true,
      'imaging exposureStarted': false,
      'imaging temperatureChanged': true,
      'imaging integrationProgress': true,
      'imaging imageSaved': false,
      'guiding correction': true,
      'guiding guideStats': true,
      'guiding guidingStarted': false,
      'equipment cameraTemperatureChanged': true,
      'equipment AutofocusProgress': true,
      'equipment Gain': false,
      'equipment connected': false,
      'sequencer instructionProgress': true,
      'sequencer progress': true,
      'sequencer ditherPerformed': false,
      'sequencer frameWatchReport': false,
      'sequencer completed': false,
      'wire settingsChanged': false,
      'wire JobProgress': false,
      // No producer sends this name.
      'wire MountPositionChanged': false,
    });
  });
}
