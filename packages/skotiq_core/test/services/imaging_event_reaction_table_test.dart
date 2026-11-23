// Which imaging-family events the imaging readers take: the DepthLock goal
// list's refresh filter, the post-session integration progress stream and the
// Darkroom pass recorder. One row per event over both transports. Pinned on
// the readers that compared event names, so the typed readers can be checked
// against it.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart' show isDepthLockEvent;
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/services/darkroom_pass/pass_recorder.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

import '../harness/event_wire.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

typedef I = bridge.ImagingEvent;

final _rows = <String, bridge.EventPayload>{
  'exposureStarted': const bridge.EventPayload.imaging(
    I.exposureStarted(durationSecs: 30, frameType: bridge.FrameType.light),
  ),
  'exposureProgress': const bridge.EventPayload.imaging(
    I.exposureProgress(progress: 0.5, remainingSecs: 15),
  ),
  'exposureCompleted': const bridge.EventPayload.imaging(
    I.exposureCompleted(filePath: '/f.fits', hfr: 2.1, starsDetected: 40),
  ),
  'exposureCompletedWithFrame': const bridge.EventPayload.imaging(
    I.exposureCompletedWithFrame(
      frameNumber: 2,
      totalFrames: 10,
      hfr: 2.1,
      starsDetected: 40,
    ),
  ),
  'exposureFailed': const bridge.EventPayload.imaging(
    I.exposureFailed(error: 'timeout'),
  ),
  'exposureFailedOld': const bridge.EventPayload.imaging(
    I.exposureFailedOld(reason: 'timeout'),
  ),
  'exposureCancelled': const bridge.EventPayload.imaging(I.exposureCancelled()),
  'imageReady': const bridge.EventPayload.imaging(
    I.imageReady(width: 10, height: 10),
  ),
  'imageSaved': const bridge.EventPayload.imaging(
    I.imageSaved(filePath: '/f.fits'),
  ),
  'integrationProgress': const bridge.EventPayload.imaging(
    I.integrationProgress(
      phase: 'registering',
      fraction: 0.25,
      framesDone: 3,
      framesTotal: 12,
    ),
  ),
  'integrationTelemetry': const bridge.EventPayload.imaging(
    I.integrationTelemetry(
      runId: 'run/1',
      kind: 'started',
      detailJson: '{"frames":12}',
    ),
  ),
  'temperatureChanged': const bridge.EventPayload.imaging(
    I.temperatureChanged(tempCelsius: -10, coolerPower: 30),
  ),
  'exposureComplete': const bridge.EventPayload.imaging(
    I.exposureComplete(success: true),
  ),
  'depthLock goalChanged': bridge.EventPayload.depthLock(
    bridge.DepthLockEvent.goalChanged(
      goalId: 'g1',
      revision: BigInt.two,
      change: 'edited',
    ),
  ),
  'sequencer DepthGoalCompleted': bridge.EventPayload.sequencer(
    bridge.SequencerEvent.depthGoalCompleted(
      nodeId: 'n1',
      filterName: 'L',
      goalId: 'g1',
      revision: BigInt.two,
      score: 1,
      threshold: 1,
      evidenceFrames: 10,
      confirmationFrames: 2,
    ),
  ),
};

Future<String> _reaction(SkotiqEvent event, Directory base) async {
  final backend = _MockBackend();
  final events = StreamController<SkotiqEvent>.broadcast();
  when(() => backend.eventStream).thenAnswer((_) => events.stream);
  final progress = <String>[];
  final seam = BridgePostSessionSeam(backend: backend);
  final sub = seam.integrationProgress().listen(
    (p) => progress.add('${p.phase}@${p.fraction}'),
  );
  final recorder = DarkroomPassRecorder(
    events: events.stream,
    baseDirectory: () async => base.path,
    saveDelay: const Duration(milliseconds: 1),
  );
  events.add(event);
  await Future<void>.delayed(Duration.zero);
  final pass = recorder.live('run/1');
  final out = [
    'depthLock=${isDepthLockEvent(event)}',
    'progress=$progress',
    'pass=${pass == null ? null : recorder.running}',
  ].join(' ');
  await sub.cancel();
  await recorder.dispose();
  await events.close();
  return out;
}

void main() {
  late Directory base;
  setUp(() => base = Directory.systemTemp.createTempSync('imaging_table'));
  tearDown(() => base.deleteSync(recursive: true));

  test('imaging readers take these events', () async {
    final table = <String, String>{};
    for (final row in _rows.entries) {
      final ffi = await _reaction(ffiWireEvent(row.value), base);
      final network = await _reaction(networkWireEvent(row.value), base);
      expect(network, ffi, reason: '${row.key}: the transports disagree');
      table[row.key] = ffi;
    }
    table['wire ImageCaptured'] = await _reaction(
      unsentWireEvent(EventCategory.imaging, 'ImageCaptured'),
      base,
    );
    const start = _Start.any;
    expect(table, _expected[start]);
  });
}

enum _Start { any }

const Map<_Start, Map<String, String>> _expected = {
  _Start.any: {
    'exposureStarted': 'depthLock=false progress=[] pass=null',
    'exposureProgress': 'depthLock=false progress=[] pass=null',
    'exposureCompleted': 'depthLock=false progress=[] pass=null',
    'exposureCompletedWithFrame': 'depthLock=false progress=[] pass=null',
    'exposureFailed': 'depthLock=false progress=[] pass=null',
    'exposureFailedOld': 'depthLock=false progress=[] pass=null',
    'exposureCancelled': 'depthLock=false progress=[] pass=null',
    'imageReady': 'depthLock=false progress=[] pass=null',
    'imageSaved': 'depthLock=false progress=[] pass=null',
    'integrationProgress':
        'depthLock=false progress=[registering@0.25] pass=null',
    'integrationTelemetry': 'depthLock=false progress=[] pass=[run/1]',
    'temperatureChanged': 'depthLock=false progress=[] pass=null',
    'exposureComplete': 'depthLock=false progress=[] pass=null',
    'depthLock goalChanged': 'depthLock=true progress=[] pass=null',
    'sequencer DepthGoalCompleted': 'depthLock=false progress=[] pass=null',
    'wire ImageCaptured': 'depthLock=false progress=[] pass=null',
  },
};
