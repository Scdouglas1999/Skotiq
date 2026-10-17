// The hop that carries per-frame capture truth out of the typed FRB payload
// and into the event `data` map every listener reads.
//
// Why this file exists: an adversarial verifier deleted
// `...frameCaptureToEventData(sequencerEvent.capture)` from BOTH the
// FrameAccepted and FrameRejected arms of
// `ffi_backend/event_mapping.dart::_extractSequencerEventInfo` and the entire
// 5204-test skotiq_core suite stayed green. That spread is the ONLY thing
// moving gain, offset, sensor temperature, cooler power, pointing, pier side,
// focuser and rotator state from the native `FrameContext` onto the map
// `SequenceExecutor._registerSequenceFrame` writes `captured_images` from.
// Drop it in a refactor and every sequenced frame silently goes back to
// landing in the database with those columns NULL while the FITS file written
// microseconds earlier carries all of them.
//
// So this suite asserts the KEYS AND VALUES survive the hop, not that some
// helper stamps a struct from its own argument. The values below are
// deliberately distinct, non-default and non-zero so a payload that arrives
// as `FrameCaptureMetadata()` defaults cannot pass.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';

/// One populated capture payload, reused by both arms so the accepted and
/// rejected paths are held to the same bar.
const _capture = bridge.FrameCaptureMetadata(
  gain: 139,
  offset: 21,
  sensorTempC: -9.5,
  coolerPowerPercent: 63.5,
  mountRaHours: 5.5,
  mountDecDegrees: -5.25,
  mountAltitudeDeg: 48.5,
  mountAzimuthDeg: 171.25,
  pierSide: 'West',
  focuserPosition: 31705,
  focuserTemperatureC: 4.25,
  rotatorAngleDeg: 212.5,
  exposureSecs: 120.0,
  binX: 2,
  binY: 2,
  frameType: 'Dark',
  targetId: 'tgt-evt',
);

/// Every capture key with the value [_capture] carries for it. Spelled out
/// literally rather than derived from `frameCaptureToEventData` so the check
/// cannot pass by comparing the mapper against itself.
const _expected = <String, Object>{
  'gain': 139,
  'offset': 21,
  'sensor_temp_c': -9.5,
  'cooler_power_percent': 63.5,
  'mount_ra_hours': 5.5,
  'mount_dec_degrees': -5.25,
  'mount_altitude_deg': 48.5,
  'mount_azimuth_deg': 171.25,
  'pier_side': 'West',
  'focuser_position': 31705,
  'focuser_temperature_c': 4.25,
  'rotator_angle_deg': 212.5,
  'exposure_secs': 120.0,
  'bin_x': 2,
  'bin_y': 2,
  'frame_type': 'Dark',
  'target_id': 'tgt-evt',
};

void main() {
  late FfiBackend backend;

  setUp(() => backend = FfiBackend());
  tearDown(() => backend.dispose());

  void expectCarriesCapture(Map<String, dynamic> data) {
    for (final entry in _expected.entries) {
      expect(
        data.containsKey(entry.key),
        isTrue,
        reason:
            'the frame event lost the "${entry.key}" key, so '
            'captured_images.${entry.key} goes back to NULL for every '
            'sequenced frame',
      );
      expect(
        data[entry.key],
        entry.value,
        reason: 'wrong value for ${entry.key}',
      );
    }
    // The same map, read back through the consumer that actually writes the
    // row. Chains this test to the persistence suite: what is asserted above
    // is exactly what `_registerSequenceFrame` will see.
    final readBack = FrameCapture.fromEventData(data);
    expect(readBack.gain, 139);
    expect(readBack.mountAltitudeDeg, 48.5);
    expect(readBack.pierSide, 'West');
    expect(readBack.focuserPosition, 31705);
    expect(readBack.frameType, 'Dark');
  }

  test('FrameAccepted carries the capture payload into the event data', () {
    final (eventType, data) = backend.sequencerEventInfoForTesting(
      const bridge.SequencerEvent.frameAccepted(
        nodeId: 'node-7',
        frame: 7,
        total: 10,
        hfr: 2.4,
        eccentricity: 0.31,
        starCount: 412,
        acceptedTotal: 7,
        rejectedTotal: 0,
        savePath: '/captures/evt_0007.fits',
        capture: _capture,
      ),
    );

    expect(eventType, 'FrameAccepted');
    expectCarriesCapture(data);
  });

  test('FrameRejected carries the capture payload into the event data', () {
    // A rejected frame is still written to disk and still gets a row, so it
    // needs the same metadata as an accepted one — the arms drift apart
    // exactly because nothing held them together.
    final (eventType, data) = backend.sequencerEventInfoForTesting(
      const bridge.SequencerEvent.frameRejected(
        nodeId: 'node-7',
        frame: 8,
        total: 10,
        reason: 'HFR 4.9 above threshold 3.5',
        hfr: 4.9,
        eccentricity: 0.62,
        starCount: 88,
        rejectPath: '/captures/Reject/evt_0008.fits',
        consecutiveRejects: 1,
        acceptedTotal: 7,
        rejectedTotal: 1,
        evidence: <String>[],
        capture: _capture,
      ),
    );

    expect(eventType, 'FrameRejected');
    expectCarriesCapture(data);
  });
}
