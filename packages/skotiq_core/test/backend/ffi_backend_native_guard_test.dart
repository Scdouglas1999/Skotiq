// Every FfiBackend operation that needs the native library refuses without it
// and names itself in the refusal. The operation name is a string passed next
// to the generated call, so the one thing a copy-paste can get wrong is which
// name a method reports. `flutter test` has no loadable `libskotiq_bridge`,
// so the refusing branch is the one that runs here.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show NativeBridge;
import 'package:skotiq_core/skotiq_core.dart';

Map<String, Future<void> Function()> _sequencerOperations(FfiBackend b) => {
  'sequencerSetDevices': () => b.sequencerSetDevices(cameraId: 'c'),
  'sequencerApplyRunConfig': () => b.sequencerApplyRunConfig('{}'),
  'sequencerSetSavePath': () => b.sequencerSetSavePath('/tmp'),
  'sequencerSetActiveSequenceRunId': () => b.sequencerSetActiveSequenceRunId(1),
  'sequencerUpdatePendingIntegrationCarryOver': () =>
      b.sequencerUpdatePendingIntegrationCarryOver(const {}),
  'sequencerSkip': b.sequencerSkip,
  'sequencerSkipToNode': () => b.sequencerSkipToNode('n1'),
  'sequencerPluginNodeFinished': () =>
      b.sequencerPluginNodeFinished(nodeId: 'n1', success: true),
  'sequencerSetCheckpointDir': () => b.sequencerSetCheckpointDir('/tmp/ckpt'),
  'sequencerHasCheckpoint': b.hasCheckpoint,
  'performMeridianFlip': () => b.performMeridianFlip(
    mountId: 'm',
    targetName: 't',
    targetRaHours: 1,
    targetDecDegrees: 2,
    pauseGuiding: true,
    autoCenter: true,
    refocusAfter: false,
    resumeGuiding: true,
    settleTimeSecs: 5,
  ),
  'sequencerDiscardCheckpoint': b.discardCheckpoint,
  'sequencerSaveCheckpoint': b.saveCheckpoint,
  'sequencerRequestMeridianFlip': b.sequencerRequestMeridianFlip,
  'sequencerLoadJson': () => b.sequencerLoadJson('{}'),
  'sequencerStart': b.sequencerStart,
  'sequencerPause': b.sequencerPause,
  'sequencerResume': b.sequencerResume,
  'sequencerStop': b.sequencerStop,
  'sequencerReset': b.sequencerReset,
  'sequencerSetSimulationMode': () => b.sequencerSetSimulationMode(true),
  'sequencerGetStatus': b.sequencerGetStatus,
  'sequencerGetCheckpointInfo': b.getCheckpointInfo,
  'sequencerResumeFromCheckpoint': b.resumeFromCheckpoint,
};

void main() {
  late FfiBackend backend;

  setUpAll(() async {
    await NativeBridge.init();
    backend = FfiBackend();
  });

  tearDownAll(() => backend.dispose());

  Matcher refuses(String name) => throwsA(
    isA<UnsupportedError>().having(
      (e) => e.message,
      'message',
      startsWith('Operation "$name" requires the native bridge.'),
    ),
  );

  test('every sequencer operation refuses under its own name', () async {
    final operations = _sequencerOperations(backend);
    expect(operations, hasLength(38));
    for (final entry in operations.entries) {
      await expectLater(entry.value(), refuses(entry.key), reason: entry.key);
    }
  });

  test('device commands refuse under the name callers already see', () async {
    await expectLater(backend.mountPark('m'), refuses('mountPark'));
    await expectLater(
      backend.cameraSetCooling(deviceId: 'c', enabled: true),
      refuses('setCameraCooler'),
    );
    await expectLater(backend.focuserHalt('f'), refuses('apiFocuserHalt'));
    await expectLater(
      backend.guiderStopGuiding(deviceId: 'phd2'),
      refuses('guiderStop'),
    );
    await expectLater(
      backend.plateSolve(imagePath: '/tmp/x.fits'),
      refuses('plateSolveBlind'),
    );
    await expectLater(
      backend.plateSolve(imagePath: '/tmp/x.fits', ra: 1, dec: 2),
      refuses('plateSolveNear'),
    );
  });

  test('status polls answer without the library instead of refusing', () async {
    final status = await backend.phd2GetStatus();
    expect(status.connected, isFalse);
    expect(status.state, 'Disconnected');
    expect(await backend.getConnectedDevices(), isEmpty);
    expect(await backend.discoverDevices(DeviceType.camera), isEmpty);
    expect(await backend.sequencerIsSimulationMode(), isFalse);
  });

  test('connecting a device without the library says so', () async {
    await expectLater(
      backend.connectDevice(DeviceType.camera, 'native:zwo:1'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'text',
          contains(
            'Cannot connect to native:zwo:1: Native bridge required but not '
            'available',
          ),
        ),
      ),
    );
    await expectLater(
      backend.connectDevice(DeviceType.guider, 'phd2:localhost:4400'),
      refuses('phd2Connect'),
    );
  });
}
