// Which host events the night's event log keeps for a client that links
// later. One row per event over the FFI path, plus names no producer sends.
// Pinned on the name set.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart' show wireEventFromTyped;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_desktop/headless_api/night_event_log.dart';

SkotiqEvent _wire(bridge.EventPayload payload, bridge.EventCategory category) =>
    wireEventFromTyped(
      bridge.SkotiqEvent(
        eventId: BigInt.one,
        timestamp: 1,
        severity: bridge.EventSeverity.info,
        category: category,
        payload: payload,
      ),
    );

bridge.EventCategory _categoryOf(bridge.EventPayload payload) =>
    switch (payload) {
      bridge.EventPayload_Equipment() => bridge.EventCategory.equipment,
      bridge.EventPayload_Imaging() => bridge.EventCategory.imaging,
      bridge.EventPayload_Guiding() => bridge.EventCategory.guiding,
      bridge.EventPayload_Sequencer() => bridge.EventCategory.sequencer,
      _ => bridge.EventCategory.system,
    };

bool _kept(SkotiqEvent event) {
  final log = NightEventLog()..append(event);
  return log.newest(1).isNotEmpty;
}

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
  test('the events the night event log keeps', () {
    final table = <String, bool>{
      for (final row in _rows.entries)
        row.key: _kept(_wire(row.value, _categoryOf(row.value))),
      'wire MountPositionChanged': _kept(
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'MountPositionChanged',
          data: {},
        ),
      ),
    };
    expect(table, <String, bool>{
      'imaging exposureProgress': false,
      'imaging exposureStarted': true,
      'imaging temperatureChanged': true,
      'imaging integrationProgress': true,
      'imaging imageSaved': true,
      'guiding correction': false,
      'guiding guideStats': false,
      'guiding guidingStarted': true,
      'equipment cameraTemperatureChanged': false,
      'equipment AutofocusProgress': false,
      'equipment Gain': true,
      'equipment connected': true,
      'sequencer instructionProgress': false,
      'sequencer progress': false,
      'sequencer ditherPerformed': false,
      'sequencer frameWatchReport': false,
      'sequencer completed': true,
      // No producer sends this name.
      'wire MountPositionChanged': true,
    });
  });

  test('integration progress keeps the newest report of each phase', () {
    SkotiqEvent progress(String phase, double fraction) => _wire(
      bridge.EventPayload.imaging(
        bridge.ImagingEvent.integrationProgress(
          phase: phase,
          fraction: fraction,
        ),
      ),
      bridge.EventCategory.imaging,
    );
    final log = NightEventLog()
      ..append(progress('registering', 0.1))
      ..append(progress('registering', 0.4))
      ..append(progress('integrating', 0.1));
    expect(
      log.newest(10).map((e) => '${e.data['phase']}@${e.data['fraction']}'),
      ['registering@0.4', 'integrating@0.1'],
    );
  });
}
