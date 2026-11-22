// What every guiding event does to the guiding providers (the PHD2 controller,
// guide statistics, guide graph, target history, lock position, calibration):
// one row per event over both transports, from a disconnected guider and from
// one that is guiding. Pinned on the readers that compared event names, so the
// typed readers can be checked against it.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/event_wire.dart';

class _RecordingBackend extends Fake implements SkotiqBackend {
  _RecordingBackend(this._events);

  final Stream<SkotiqEvent> _events;
  final List<String> calls = [];

  @override
  Stream<SkotiqEvent> get eventStream => _events;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(8, name.length - 2));
    throw UnimplementedError(name);
  }
}

/// The FFI host's backend: the readers that only run where the device bridge
/// is (the guider status channel) run on this one.
class _HostRecordingBackend extends _RecordingBackend implements FfiBackend {
  _HostRecordingBackend(super.events);
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _guiding = <String, bridge.GuidingEvent>{
  'connected': bridge.GuidingEvent.connected(),
  'disconnected': bridge.GuidingEvent.disconnected(),
  'guidingStarted': bridge.GuidingEvent.guidingStarted(),
  'guidingStopped': bridge.GuidingEvent.guidingStopped(),
  'paused': bridge.GuidingEvent.paused(),
  'resumed': bridge.GuidingEvent.resumed(),
  'settled rms': bridge.GuidingEvent.settled(rms: 0.4),
  'settled': bridge.GuidingEvent.settled(),
  'lostStar': bridge.GuidingEvent.lostStar(),
  'settleTimedOut': bridge.GuidingEvent.settleTimedOut(error: 'too slow'),
  'stopReason': bridge.GuidingEvent.stopReason(reason: 'user'),
  'stopReason none': bridge.GuidingEvent.stopReason(),
  'ditherStarted': bridge.GuidingEvent.ditherStarted(pixels: 3),
  'ditherCompleted': bridge.GuidingEvent.ditherCompleted(),
  'correction': bridge.GuidingEvent.correction(
    ra: 1,
    dec: 2,
    raRaw: 0.5,
    decRaw: -0.25,
  ),
  'looping': bridge.GuidingEvent.looping(),
  'settling': bridge.GuidingEvent.settling(),
  'calibrating': bridge.GuidingEvent.calibrating(),
  'calibrationComplete': bridge.GuidingEvent.calibrationComplete(),
  'starSelected': bridge.GuidingEvent.starSelected(x: 10, y: 20),
  'appState Guiding': bridge.GuidingEvent.appState(state: 'Guiding'),
  'appState Looping': bridge.GuidingEvent.appState(state: 'Looping'),
  'appState unknown': bridge.GuidingEvent.appState(state: 'Weird'),
  'guideStats': bridge.GuidingEvent.guideStats(snr: 12, starMass: 3000),
};

/// Names an older reader matched that no producer sends, and an event of
/// another family under a guiding name.
final _unsent = <String, SkotiqEvent>{
  'wire LostStar': unsentWireEvent(EventCategory.guiding, 'LostStar'),
  'wire UnknownGuidingEvent': unsentWireEvent(
    EventCategory.guiding,
    'UnknownGuidingEvent',
  ),
  'wire LockPositionSet': unsentWireEvent(
    EventCategory.guiding,
    'LockPositionSet',
    {'X': 4, 'Y': 5},
  ),
  'wire CalibrationFailed': unsentWireEvent(
    EventCategory.guiding,
    'CalibrationFailed',
  ),
  'wire CalibrationDataFlipped': unsentWireEvent(
    EventCategory.guiding,
    'CalibrationDataFlipped',
  ),
};

final _equipmentConnected = bridge.EventPayload.equipment(
  const bridge.EquipmentEvent.connected(
    deviceType: 'Guider',
    deviceId: 'phd2_guider',
    deviceName: 'PHD2',
  ),
);

enum _Start {
  clientDisconnected,
  clientGuiding,
  hostDisconnected,
  hostGuiding;

  bool get guiding => this == clientGuiding || this == hostGuiding;

  _RecordingBackend backend(Stream<SkotiqEvent> events) =>
      this == hostDisconnected || this == hostGuiding
      ? _HostRecordingBackend(events)
      : _RecordingBackend(events);
}

String _reaction(_Start start, SkotiqEvent event) {
  late String result;
  fakeAsync((async) {
    final events = StreamController<SkotiqEvent>.broadcast();
    final backend = start.backend(events.stream);
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    try {
      container.read(phd2ControllerProvider);
      container.read(guideStatsProvider);
      container.read(guideGraphProvider);
      container.read(targetDisplayHistoryProvider);
      container.read(lockPositionProvider);
      container.read(calibrationStateProvider);
      container.read(hostGuiderStatusProvider);
      if (start.guiding) {
        container.read(guiderStateProvider.notifier)
          ..setConnecting(kPhd2CanonicalId, kPhd2DisplayName)
          ..setConnected()
          ..setGuiding(true);
        container.read(phd2StateProvider.notifier).state = Phd2State.guiding;
        container.read(guideStatsProvider.notifier).updateStarData(5, 100);
        container.read(guideGraphProvider.notifier).addPoint(0.1, 0.2);
        container.read(targetDisplayHistoryProvider.notifier).applyHostHistory([
          GuideErrorPoint(
            raError: 0.1,
            decError: 0.2,
            timestamp: DateTime(2026),
          ),
        ]);
        container.read(lockPositionProvider.notifier).applyHostPosition((
          x: 1,
          y: 1,
        ));
      }
      async.elapse(const Duration(seconds: 3));
      backend.calls.clear();

      events.add(event);
      async.flushMicrotasks();
      final callsAtOnce = backend.calls.join(',');
      backend.calls.clear();
      async.elapse(const Duration(seconds: 3));

      final guider = container.read(guiderStateProvider);
      final stats = container.read(guideStatsProvider);
      final lock = container.read(lockPositionProvider);
      result = [
        container.read(phd2StateProvider).name,
        'conn=${guider.connectionState.name}',
        'guiding=${guider.isGuiding}',
        'rms=${guider.rmsTotal?.toStringAsFixed(3)}',
        'stop=${container.read(guidingStopReasonProvider)}',
        'settleTimeout=${container.read(guiderSettleTimeoutProvider) != null}',
        'lost=${container.read(starLostEventProvider) != null}',
        'snr=${stats.snr} mass=${stats.starMass} '
            'statsRms=${stats.rmsTotal.toStringAsFixed(3)} '
            'loop=${stats.loopFrameCount}',
        'graph=${container.read(guideGraphProvider).length}',
        'history=${container.read(targetDisplayHistoryProvider).length}',
        'lock=${lock == null ? null : '${lock.x},${lock.y}'}',
        'calibrated=${container.read(calibrationStateProvider).isCalibrated}',
        'calls=$callsAtOnce',
        'later=${backend.calls.join(',')}',
      ].join(' ');
    } finally {
      container.dispose();
      unawaited(events.close());
      async.flushMicrotasks();
    }
  });
  return result;
}

/// What the host's own window does with a guiding event that came through
/// its server.
Future<String> _hostWindowReaction(_Start start, SkotiqEvent event) async {
  final backend = start.backend(const Stream.empty());
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
  );
  try {
    if (start.guiding) {
      container.read(guiderStateProvider.notifier)
        ..setConnecting('native:builtin_guider:multi_star', 'Built-in')
        ..setConnected();
    }
    applyHostLocalSyncEvent(container, event);
    final guider = container.read(guiderStateProvider);
    return '${guider.connectionState.name} ${guider.deviceId}';
  } finally {
    container.dispose();
  }
}

void main() {
  final rows = <String, SkotiqEvent Function(EventPath)>{
    for (final entry in _guiding.entries)
      entry.key: (path) =>
          wireEventOver(path, bridge.EventPayload.guiding(entry.value)),
    for (final entry in _unsent.entries) entry.key: (_) => entry.value,
    'equipment Connected': (path) => wireEventOver(path, _equipmentConnected),
  };

  for (final start in _Start.values) {
    test('guiding event reactions from a ${start.name} guider', () async {
      final table = <String, String>{};
      for (final row in rows.entries) {
        final ffi = _reaction(start, row.value(EventPath.ffi));
        final network = _reaction(start, row.value(EventPath.network));
        expect(network, ffi, reason: '${row.key}: the transports disagree');
        table[row.key] = ffi;
      }
      expect(table, _expected[start]);
    });

    test(
      'host window follows guiding events from a ${start.name} guider',
      () async {
        final table = <String, String>{};
        for (final row in rows.entries) {
          final ffi = await _hostWindowReaction(
            start,
            row.value(EventPath.ffi),
          );
          final network = await _hostWindowReaction(
            start,
            row.value(EventPath.network),
          );
          expect(network, ffi, reason: '${row.key}: the transports disagree');
          table[row.key] = ffi;
        }
        expect(table, _hostWindowExpected[start]);
      },
    );
  }
}

const Map<_Start, Map<String, String>> _expected = {
  _Start.clientDisconnected: {
    'connected':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration,guiderGetStatus later=',
    'disconnected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'guidingStarted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetStatus,guiderGetCalibration later=',
    'guidingStopped':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'paused':
        'paused conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'resumed':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'settled rms':
        'guiding conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'settled':
        'guiding conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'lostStar':
        'lostLock conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=true snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'settleTimedOut':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'stopReason':
        'stopped conn=disconnected guiding=false rms=null stop=user settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'stopReason none':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'ditherStarted':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'ditherCompleted':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'correction':
        'stopped conn=connected guiding=false rms=0.000 stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.559 loop=0 graph=1 history=1 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'looping':
        'looping conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'settling':
        'settling conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'calibrating':
        'calibrating conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'calibrationComplete':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=true calls=guiderGetCalibration,guiderGetStatus,guiderGetStatus,guiderGetCalibration,guiderGetCalibration later=',
    'starSelected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=10.0,20.0 calibrated=false calls= later=',
    'appState Guiding':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'appState Looping':
        'looping conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'appState unknown':
        'unknown conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'guideStats':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=12.0 mass=3000.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'wire LostStar':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'wire UnknownGuidingEvent':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'wire LockPositionSet':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=4.0,5.0 calibrated=false calls= later=',
    'wire CalibrationFailed':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'wire CalibrationDataFlipped':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetCalibration later=',
    'equipment Connected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
  },
  _Start.clientGuiding: {
    'connected':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=',
    'disconnected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=0 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'guidingStarted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=0 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=',
    'guidingStopped':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=1.0,1.0 calibrated=false calls= later=',
    'paused':
        'paused conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'resumed':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'settled rms':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'settled':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'lostStar':
        'lostLock conn=connected guiding=false rms=null stop=null settleTimeout=false lost=true snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'settleTimedOut':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=true lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'stopReason':
        'guiding conn=connected guiding=true rms=null stop=user settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'stopReason none':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'ditherStarted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'ditherCompleted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'correction':
        'guiding conn=connected guiding=true rms=0.000 stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.559 loop=0 graph=2 history=2 lock=1.0,1.0 calibrated=false calls= later=',
    'looping':
        'looping conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'settling':
        'settling conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'calibrating':
        'calibrating conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'calibrationComplete':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=true calls=guiderGetCalibration,guiderGetStatus,guiderGetCalibration later=',
    'starSelected':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=10.0,20.0 calibrated=false calls= later=',
    'appState Guiding':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'appState Looping':
        'looping conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'appState unknown':
        'unknown conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'guideStats':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=12.0 mass=3000.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire LostStar':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire UnknownGuidingEvent':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire LockPositionSet':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=4.0,5.0 calibrated=false calls= later=',
    'wire CalibrationFailed':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire CalibrationDataFlipped':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetCalibration later=',
    'equipment Connected':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
  },
  _Start.hostDisconnected: {
    'connected':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetStatus,guiderGetCalibration,guiderGetStatus later=guiderGetStatus',
    'disconnected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'guidingStarted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetStatus,guiderGetCalibration later=',
    'guidingStopped':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'paused':
        'paused conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'resumed':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'settled rms':
        'guiding conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'settled':
        'guiding conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'lostStar':
        'lostLock conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=true snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'settleTimedOut':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'stopReason':
        'stopped conn=disconnected guiding=false rms=null stop=user settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'stopReason none':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'ditherStarted':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'ditherCompleted':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'correction':
        'stopped conn=connected guiding=false rms=0.000 stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.559 loop=0 graph=1 history=1 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'looping':
        'looping conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'settling':
        'settling conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'calibrating':
        'calibrating conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'calibrationComplete':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=true calls=guiderGetCalibration,guiderGetStatus,guiderGetStatus,guiderGetCalibration,guiderGetCalibration later=',
    'starSelected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=10.0,20.0 calibrated=false calls= later=',
    'appState Guiding':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'appState Looping':
        'looping conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'appState unknown':
        'unknown conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'guideStats':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=12.0 mass=3000.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetStatus,guiderGetCalibration later=',
    'wire LostStar':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'wire UnknownGuidingEvent':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'wire LockPositionSet':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=4.0,5.0 calibrated=false calls= later=',
    'wire CalibrationFailed':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
    'wire CalibrationDataFlipped':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls=guiderGetCalibration later=',
    'equipment Connected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=null calibrated=false calls= later=',
  },
  _Start.hostGuiding: {
    'connected':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus,guiderGetStatus later=guiderGetStatus',
    'disconnected':
        'stopped conn=disconnected guiding=false rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=0 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'guidingStarted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=0 lock=1.0,1.0 calibrated=false calls=guiderGetStatus,guiderGetStatus later=guiderGetStatus',
    'guidingStopped':
        'stopped conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.000 loop=0 graph=0 history=0 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'paused':
        'paused conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'resumed':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'settled rms':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'settled':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'lostStar':
        'lostLock conn=connected guiding=false rms=null stop=null settleTimeout=false lost=true snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'settleTimedOut':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=true lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'stopReason':
        'guiding conn=connected guiding=true rms=null stop=user settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'stopReason none':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'ditherStarted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'ditherCompleted':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'correction':
        'guiding conn=connected guiding=true rms=0.000 stop=null settleTimeout=false lost=false snr=0.0 mass=0.0 statsRms=0.559 loop=0 graph=2 history=2 lock=1.0,1.0 calibrated=false calls= later=',
    'looping':
        'looping conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'settling':
        'settling conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'calibrating':
        'calibrating conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'calibrationComplete':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=true calls=guiderGetCalibration,guiderGetStatus,guiderGetCalibration,guiderGetStatus later=guiderGetStatus',
    'starSelected':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=10.0,20.0 calibrated=false calls= later=',
    'appState Guiding':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'appState Looping':
        'looping conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'appState unknown':
        'unknown conn=connected guiding=false rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetStatus later=guiderGetStatus',
    'guideStats':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=12.0 mass=3000.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire LostStar':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire UnknownGuidingEvent':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire LockPositionSet':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=4.0,5.0 calibrated=false calls= later=',
    'wire CalibrationFailed':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
    'wire CalibrationDataFlipped':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls=guiderGetCalibration later=',
    'equipment Connected':
        'guiding conn=connected guiding=true rms=null stop=null settleTimeout=false lost=false snr=5.0 mass=100.0 statsRms=0.000 loop=0 graph=1 history=1 lock=1.0,1.0 calibrated=false calls= later=',
  },
};
const Map<_Start, Map<String, String>> _hostWindowExpected = {
  _Start.clientDisconnected: {
    'connected': 'connected phd2_guider',
    'disconnected': 'disconnected null',
    'guidingStarted': 'disconnected null',
    'guidingStopped': 'disconnected null',
    'paused': 'disconnected null',
    'resumed': 'disconnected null',
    'settled rms': 'disconnected null',
    'settled': 'disconnected null',
    'lostStar': 'disconnected null',
    'settleTimedOut': 'disconnected null',
    'stopReason': 'disconnected null',
    'stopReason none': 'disconnected null',
    'ditherStarted': 'disconnected null',
    'ditherCompleted': 'disconnected null',
    'correction': 'disconnected null',
    'looping': 'disconnected null',
    'settling': 'disconnected null',
    'calibrating': 'disconnected null',
    'calibrationComplete': 'disconnected null',
    'starSelected': 'disconnected null',
    'appState Guiding': 'disconnected null',
    'appState Looping': 'disconnected null',
    'appState unknown': 'disconnected null',
    'guideStats': 'disconnected null',
    'wire LostStar': 'disconnected null',
    'wire UnknownGuidingEvent': 'disconnected null',
    'wire LockPositionSet': 'disconnected null',
    'wire CalibrationFailed': 'disconnected null',
    'wire CalibrationDataFlipped': 'disconnected null',
    'equipment Connected': 'connected phd2_guider',
  },
  _Start.clientGuiding: {
    'connected': 'connected native:builtin_guider:multi_star',
    'disconnected': 'disconnected null',
    'guidingStarted': 'connected native:builtin_guider:multi_star',
    'guidingStopped': 'connected native:builtin_guider:multi_star',
    'paused': 'connected native:builtin_guider:multi_star',
    'resumed': 'connected native:builtin_guider:multi_star',
    'settled rms': 'connected native:builtin_guider:multi_star',
    'settled': 'connected native:builtin_guider:multi_star',
    'lostStar': 'connected native:builtin_guider:multi_star',
    'settleTimedOut': 'connected native:builtin_guider:multi_star',
    'stopReason': 'connected native:builtin_guider:multi_star',
    'stopReason none': 'connected native:builtin_guider:multi_star',
    'ditherStarted': 'connected native:builtin_guider:multi_star',
    'ditherCompleted': 'connected native:builtin_guider:multi_star',
    'correction': 'connected native:builtin_guider:multi_star',
    'looping': 'connected native:builtin_guider:multi_star',
    'settling': 'connected native:builtin_guider:multi_star',
    'calibrating': 'connected native:builtin_guider:multi_star',
    'calibrationComplete': 'connected native:builtin_guider:multi_star',
    'starSelected': 'connected native:builtin_guider:multi_star',
    'appState Guiding': 'connected native:builtin_guider:multi_star',
    'appState Looping': 'connected native:builtin_guider:multi_star',
    'appState unknown': 'connected native:builtin_guider:multi_star',
    'guideStats': 'connected native:builtin_guider:multi_star',
    'wire LostStar': 'connected native:builtin_guider:multi_star',
    'wire UnknownGuidingEvent': 'connected native:builtin_guider:multi_star',
    'wire LockPositionSet': 'connected native:builtin_guider:multi_star',
    'wire CalibrationFailed': 'connected native:builtin_guider:multi_star',
    'wire CalibrationDataFlipped': 'connected native:builtin_guider:multi_star',
    'equipment Connected': 'connected phd2_guider',
  },
  _Start.hostDisconnected: {
    'connected': 'connected phd2_guider',
    'disconnected': 'disconnected null',
    'guidingStarted': 'disconnected null',
    'guidingStopped': 'disconnected null',
    'paused': 'disconnected null',
    'resumed': 'disconnected null',
    'settled rms': 'disconnected null',
    'settled': 'disconnected null',
    'lostStar': 'disconnected null',
    'settleTimedOut': 'disconnected null',
    'stopReason': 'disconnected null',
    'stopReason none': 'disconnected null',
    'ditherStarted': 'disconnected null',
    'ditherCompleted': 'disconnected null',
    'correction': 'disconnected null',
    'looping': 'disconnected null',
    'settling': 'disconnected null',
    'calibrating': 'disconnected null',
    'calibrationComplete': 'disconnected null',
    'starSelected': 'disconnected null',
    'appState Guiding': 'disconnected null',
    'appState Looping': 'disconnected null',
    'appState unknown': 'disconnected null',
    'guideStats': 'disconnected null',
    'wire LostStar': 'disconnected null',
    'wire UnknownGuidingEvent': 'disconnected null',
    'wire LockPositionSet': 'disconnected null',
    'wire CalibrationFailed': 'disconnected null',
    'wire CalibrationDataFlipped': 'disconnected null',
    'equipment Connected': 'connected phd2_guider',
  },
  _Start.hostGuiding: {
    'connected': 'connected native:builtin_guider:multi_star',
    'disconnected': 'disconnected null',
    'guidingStarted': 'connected native:builtin_guider:multi_star',
    'guidingStopped': 'connected native:builtin_guider:multi_star',
    'paused': 'connected native:builtin_guider:multi_star',
    'resumed': 'connected native:builtin_guider:multi_star',
    'settled rms': 'connected native:builtin_guider:multi_star',
    'settled': 'connected native:builtin_guider:multi_star',
    'lostStar': 'connected native:builtin_guider:multi_star',
    'settleTimedOut': 'connected native:builtin_guider:multi_star',
    'stopReason': 'connected native:builtin_guider:multi_star',
    'stopReason none': 'connected native:builtin_guider:multi_star',
    'ditherStarted': 'connected native:builtin_guider:multi_star',
    'ditherCompleted': 'connected native:builtin_guider:multi_star',
    'correction': 'connected native:builtin_guider:multi_star',
    'looping': 'connected native:builtin_guider:multi_star',
    'settling': 'connected native:builtin_guider:multi_star',
    'calibrating': 'connected native:builtin_guider:multi_star',
    'calibrationComplete': 'connected native:builtin_guider:multi_star',
    'starSelected': 'connected native:builtin_guider:multi_star',
    'appState Guiding': 'connected native:builtin_guider:multi_star',
    'appState Looping': 'connected native:builtin_guider:multi_star',
    'appState unknown': 'connected native:builtin_guider:multi_star',
    'guideStats': 'connected native:builtin_guider:multi_star',
    'wire LostStar': 'connected native:builtin_guider:multi_star',
    'wire UnknownGuidingEvent': 'connected native:builtin_guider:multi_star',
    'wire LockPositionSet': 'connected native:builtin_guider:multi_star',
    'wire CalibrationFailed': 'connected native:builtin_guider:multi_star',
    'wire CalibrationDataFlipped': 'connected native:builtin_guider:multi_star',
    'equipment Connected': 'connected phd2_guider',
  },
};
