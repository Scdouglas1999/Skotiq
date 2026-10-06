/// Parity tests for the sequencer bridge's fail-closed contract.
///
/// Every sequencer operation refuses to run without the native library and
/// names itself in the refusal. The de-boilerplating of `sequencer_operations`
/// moved that guard into a shared `_native` helper, which takes the operation
/// name as a string — so the one thing a copy-paste can silently get wrong is
/// which name a method reports. This pins all of them.
///
/// `flutter test` has no loadable `libnightshade_bridge` on its loader path, so
/// this is the fallback branch every time, which is exactly the branch under
/// test.

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_bridge/nightshade_bridge.dart';

/// Operations rewritten onto the shared `_native` helper.
final _collapsed = <String, Future<void> Function()>{
  'sequencerSetDevices': () => NativeBridge.sequencerSetDevices(cameraId: 'c'),
  'sequencerSetSafetyFailMode': () =>
      NativeBridge.sequencerSetSafetyFailMode('abort'),
  'sequencerSetParkPolicy': () => NativeBridge.sequencerSetParkPolicy(
    parkOnUnsafeWeather: true,
    parkBeforeDawn: true,
  ),
  'sequencerSetDeviceRetries': () => NativeBridge.sequencerSetDeviceRetries(
    cameraRetries: 3,
    filterWheelRetries: 3,
  ),
  'sequencerSetSafetyCheckIntervalSeconds': () =>
      NativeBridge.sequencerSetSafetyCheckIntervalSeconds(30),
  'sequencerSetSavePath': () => NativeBridge.sequencerSetSavePath(path: '/tmp'),
  'sequencerSetActiveSequenceRunId': () =>
      NativeBridge.sequencerSetActiveSequenceRunId(sequenceRunId: 1),
  'sequencerSetDecisionLoggingEnabled': () =>
      NativeBridge.sequencerSetDecisionLoggingEnabled(enabled: true),
  'sequencerUpdateDitherConfig': () => NativeBridge.sequencerUpdateDitherConfig(
    pixels: 3,
    settlePixels: 1.5,
    settleTime: 5,
    settleTimeout: 40,
    raOnly: false,
  ),
  'sequencerUpdateMeridianFlipConfig': () =>
      NativeBridge.sequencerUpdateMeridianFlipConfig(configJson: '{}'),
  'sequencerUpdateLocation': () =>
      NativeBridge.sequencerUpdateLocation(latitude: 40, longitude: -105),
  'sequencerUpdateFilterOffsets': () =>
      NativeBridge.sequencerUpdateFilterOffsets(offsets: const {'L': 0}),
  'sequencerUpdatePendingIntegrationCarryOver': () =>
      NativeBridge.sequencerUpdatePendingIntegrationCarryOver(
        carryOver: const {
          'M31': {'L': 600.0},
        },
      ),
  'sequencerUpdateAutofocusConfig': () =>
      NativeBridge.sequencerUpdateAutofocusConfig(configJson: '{}'),
  'sequencerUpdateAutofocusInterval': () =>
      NativeBridge.sequencerUpdateAutofocusInterval(everyNFrames: 25),
  'sequencerUpdateDefaultQualityCheck': () =>
      NativeBridge.sequencerUpdateDefaultQualityCheck(
        maxConsecutiveRejects: 3,
        enabled: true,
      ),
  'sequencerUpdateRejectFolderPath': () =>
      NativeBridge.sequencerUpdateRejectFolderPath(path: '/tmp/reject'),
  'sequencerUpdateObserverProfile': () =>
      NativeBridge.sequencerUpdateObserverProfile(observerName: 'observer'),
  'sequencerSkip': NativeBridge.sequencerSkip,
  'sequencerSkipToNode': () => NativeBridge.sequencerSkipToNode(nodeId: 'n1'),
  'sequencerPluginNodeFinished': () =>
      NativeBridge.sequencerPluginNodeFinished(nodeId: 'n1', success: true),
  'sequencerSetCheckpointDir': () =>
      NativeBridge.sequencerSetCheckpointDir('/tmp/ckpt'),
  'sequencerHasCheckpoint': NativeBridge.sequencerHasCheckpoint,
  'performMeridianFlip': () => NativeBridge.performMeridianFlip(
    mountId: 'm',
    targetName: 'M31',
    targetRaHours: 0.7,
    targetDecDegrees: 41.3,
    pauseGuiding: true,
    autoCenter: true,
    refocusAfter: false,
    resumeGuiding: true,
    settleTimeSecs: 5,
  ),
  'sequencerDiscardCheckpoint': NativeBridge.sequencerDiscardCheckpoint,
  'sequencerSaveCheckpoint': NativeBridge.sequencerSaveCheckpoint,
};

/// Operations left verbatim because they carry Dart-side state or mapping.
final _stateful = <String, Future<void> Function()>{
  'sequencerSubscribeEvents': NativeBridge.sequencerSubscribeEvents,
  'sequencerLoadJson': () => NativeBridge.sequencerLoadJson('{}'),
  'sequencerStart': NativeBridge.sequencerStart,
  'sequencerPause': NativeBridge.sequencerPause,
  'sequencerResume': NativeBridge.sequencerResume,
  'sequencerStop': NativeBridge.sequencerStop,
  'sequencerReset': NativeBridge.sequencerReset,
  'sequencerSetSimulationMode': () =>
      NativeBridge.sequencerSetSimulationMode(true),
  'sequencerGetStatus': NativeBridge.sequencerGetStatus,
  'sequencerGetCheckpointInfo': NativeBridge.sequencerGetCheckpointInfo,
  'sequencerResumeFromCheckpoint': NativeBridge.sequencerResumeFromCheckpoint,
};

void main() {
  setUpAll(() async {
    await NativeBridge.init();
  });

  void pinRefusal(Map<String, Future<void> Function()> operations) {
    operations.forEach((name, invoke) {
      test('$name refuses under its own name', () async {
        await expectLater(
          invoke(),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              startsWith('Operation "$name" requires the native bridge.'),
            ),
          ),
        );
      });
    });
  }

  group('collapsed onto the shared guard', () => pinRefusal(_collapsed));
  group('left verbatim', () => pinRefusal(_stateful));

  test('every sequencer operation is covered', () {
    expect(_collapsed.length + _stateful.length, 37);
  });
}
