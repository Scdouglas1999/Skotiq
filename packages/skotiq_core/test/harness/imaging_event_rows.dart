// One event of every imaging-family variant, plus the neighbors a reader of
// imaging events must tell apart from them, for the per-reader tables.

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

typedef _I = bridge.ImagingEvent;

final Map<String, bridge.EventPayload> imagingEventRows = {
  'exposureStarted': const bridge.EventPayload.imaging(
    _I.exposureStarted(durationSecs: 30, frameType: bridge.FrameType.light),
  ),
  'exposureStartedWithFrame': const bridge.EventPayload.imaging(
    _I.exposureStartedWithFrame(
      durationSecs: 30,
      frameType: bridge.FrameType.light,
      frameNumber: 2,
      totalFrames: 10,
    ),
  ),
  'exposureProgress': const bridge.EventPayload.imaging(
    _I.exposureProgress(progress: 0.5, remainingSecs: 15),
  ),
  'exposureCompleted': const bridge.EventPayload.imaging(
    _I.exposureCompleted(filePath: '/f.fits', hfr: 2.1, starsDetected: 40),
  ),
  'exposureCompletedWithFrame': const bridge.EventPayload.imaging(
    _I.exposureCompletedWithFrame(
      frameNumber: 2,
      totalFrames: 10,
      hfr: 2.1,
      starsDetected: 40,
    ),
  ),
  'exposureFailed': const bridge.EventPayload.imaging(
    _I.exposureFailed(error: 'timeout'),
  ),
  'exposureFailedOld': const bridge.EventPayload.imaging(
    _I.exposureFailedOld(reason: 'timeout'),
  ),
  'exposureCancelled': const bridge.EventPayload.imaging(
    _I.exposureCancelled(),
  ),
  'downloadStarted': const bridge.EventPayload.imaging(_I.downloadStarted()),
  'downloadCompleted': const bridge.EventPayload.imaging(
    _I.downloadCompleted(),
  ),
  'imageReady': const bridge.EventPayload.imaging(
    _I.imageReady(width: 10, height: 10),
  ),
  'imageSaved': const bridge.EventPayload.imaging(
    _I.imageSaved(filePath: '/f.fits'),
  ),
  'integrationProgress': const bridge.EventPayload.imaging(
    _I.integrationProgress(phase: 'registering', fraction: 0.25),
  ),
  'integrationTelemetry': const bridge.EventPayload.imaging(
    _I.integrationTelemetry(
      runId: 'run/1',
      kind: 'started',
      detailJson: '{"frames":12}',
    ),
  ),
  'temperatureChanged': const bridge.EventPayload.imaging(
    _I.temperatureChanged(tempCelsius: -10, coolerPower: 30),
  ),
  'exposureComplete ok': const bridge.EventPayload.imaging(
    _I.exposureComplete(success: true),
  ),
  'exposureComplete failed': const bridge.EventPayload.imaging(
    _I.exposureComplete(success: false),
  ),
  'depthLock goalChanged': bridge.EventPayload.depthLock(
    bridge.DepthLockEvent.goalChanged(
      goalId: 'g1',
      revision: BigInt.two,
      change: 'edited',
    ),
  ),
  'sequencer ExposureCompleted': const bridge.EventPayload.sequencer(
    bridge.SequencerEvent.exposureCompleted(
      frame: 1,
      total: 4,
      durationSecs: 30,
    ),
  ),
};
