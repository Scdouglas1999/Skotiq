// What every equipment event does to the device slots: the device service's
// handler (and the device-state applier it shares with a slave's mirror) and
// the host window's mirror of devices connected through its server. One row
// per event over both transports, from empty slots and from slots holding
// the devices the events name. Pinned on the readers that compared event
// names, so the typed readers can be checked against it.
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/event_wire.dart';
import '../harness/in_memory_database.dart';

class _RecordingBackend extends Fake implements SkotiqBackend {
  _RecordingBackend(this._events);

  final Stream<SkotiqEvent> _events;
  final List<String> calls = [];

  @override
  Stream<SkotiqEvent> get eventStream => _events;

  @override
  void dispose() {}

  @override
  Set<DeviceType> get nativeReconnectedDeviceTypes => DeviceType.values.toSet();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(8, name.length - 2));
    throw UnimplementedError(name);
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

typedef E = bridge.EquipmentEvent;

final _equipment = <String, E>{
  'connecting camera': const E.connecting(
    deviceType: 'camera',
    deviceId: 'cam1',
    deviceName: 'Cam',
  ),
  'connected camera': const E.connected(
    deviceType: 'camera',
    deviceId: 'cam1',
    deviceName: 'Cam',
  ),
  'connected mount': const E.connected(
    deviceType: 'mount',
    deviceId: 'mount1',
    deviceName: 'Mount',
  ),
  'disconnected camera': const E.disconnected(
    deviceType: 'camera',
    deviceId: 'cam1',
  ),
  'disconnected other': const E.disconnected(
    deviceType: 'camera',
    deviceId: 'other',
  ),
  'propertyChanged gain': const E.propertyChanged(
    deviceType: 'camera',
    deviceId: 'cam1',
    property: 'gain',
    value: '120',
  ),
  'propertyChanged device_change': const E.propertyChanged(
    deviceType: 'camera',
    deviceId: 'cam1',
    property: 'device_change',
    value: '',
  ),
  'propertyChanged AutofocusProgress': const E.propertyChanged(
    deviceType: 'focuser',
    deviceId: 'foc1',
    property: 'AutofocusProgress',
    value: '{"phase":"moving"}',
  ),
  'propertyChanged FocuserBacklashCalibrationProgress': const E.propertyChanged(
    deviceType: 'focuser',
    deviceId: 'foc1',
    property: 'FocuserBacklashCalibrationProgress',
    value: '{}',
  ),
  'error camera': const E.error(
    deviceType: 'camera',
    deviceId: 'cam1',
    message: 'USB gone',
  ),
  'error camera warning': const E.error(
    deviceType: 'camera',
    deviceId: 'cam1',
    message: 'Cooler set-point was not restored',
  ),
  'mountSlewStarted': const E.mountSlewStarted(
    deviceId: 'mount1',
    ra: 1,
    dec: 2,
  ),
  'mountSlewStarted other': const E.mountSlewStarted(
    deviceId: 'other',
    ra: 1,
    dec: 2,
  ),
  'mountSlewCompleted': const E.mountSlewCompleted(
    deviceId: 'mount1',
    ra: 1,
    dec: 2,
  ),
  'mountTrackingStarted': const E.mountTrackingStarted(deviceId: 'mount1'),
  'mountTrackingStopped': const E.mountTrackingStopped(deviceId: 'mount1'),
  'mountParkStarted': const E.mountParkStarted(deviceId: 'mount1'),
  'mountParkCompleted': const E.mountParkCompleted(deviceId: 'mount1'),
  'mountUnparked': const E.mountUnparked(deviceId: 'mount1'),
  'focuserMoveStarted': const E.focuserMoveStarted(
    deviceId: 'foc1',
    targetPosition: 500,
  ),
  'focuserMoveCompleted': const E.focuserMoveCompleted(
    deviceId: 'foc1',
    position: 510,
  ),
  'focuserMoveCompleted other': const E.focuserMoveCompleted(
    deviceId: 'other',
    position: 510,
  ),
  'filterChanging': const E.filterChanging(
    deviceId: 'fw1',
    fromPosition: 0,
    toPosition: 2,
    filterName: 'Ha',
    fromFilterName: 'L',
  ),
  'filterChanged': const E.filterChanged(
    deviceId: 'fw1',
    position: 2,
    filterName: 'Ha',
  ),
  'rotatorMoveStarted': const E.rotatorMoveStarted(
    deviceId: 'rot1',
    targetAngle: 90,
  ),
  'rotatorMoveCompleted': const E.rotatorMoveCompleted(
    deviceId: 'rot1',
    angle: 91.5,
  ),
  'cameraCoolingStarted': const E.cameraCoolingStarted(
    deviceId: 'cam1',
    targetTemp: -10,
  ),
  'cameraCoolingReached': const E.cameraCoolingReached(
    deviceId: 'cam1',
    temperature: -10,
  ),
  'cameraWarmingStarted': const E.cameraWarmingStarted(deviceId: 'cam1'),
  'cameraWarmingCompleted': const E.cameraWarmingCompleted(deviceId: 'cam1'),
  'cameraTemperatureChanged': const E.cameraTemperatureChanged(
    deviceId: 'cam1',
    temperature: -5.5,
    coolerPower: 40,
  ),
  'cameraTemperatureChanged no power': const E.cameraTemperatureChanged(
    deviceId: 'cam1',
    temperature: -5.5,
  ),
  'cameraSettingsChanged': const E.cameraSettingsChanged(
    deviceId: 'cam1',
    gain: 100,
    gainIsIso: false,
    offset: 10,
    binX: 2,
    binY: 2,
  ),
  'cameraRetainedCapturesChanged': const E.cameraRetainedCapturesChanged(
    deviceId: 'cam1',
    count: 3,
  ),
  'heartbeatStarted': E.heartbeatStarted(
    deviceType: 'camera',
    deviceId: 'cam1',
    intervalSecs: BigInt.from(5),
  ),
  'heartbeatStopped': const E.heartbeatStopped(
    deviceType: 'camera',
    deviceId: 'cam1',
  ),
  'heartbeatStatusChanged degraded': E.heartbeatStatusChanged(
    deviceType: 'camera',
    deviceId: 'cam1',
    status: bridge.HeartbeatStatus.degraded,
    consecutiveFailures: 2,
    lastRttMs: BigInt.from(120),
  ),
  'heartbeatStatusChanged disconnected': const E.heartbeatStatusChanged(
    deviceType: 'camera',
    deviceId: 'cam1',
    status: bridge.HeartbeatStatus.disconnected,
    consecutiveFailures: 5,
  ),
  'heartbeatReconnecting': const E.heartbeatReconnecting(
    deviceType: 'camera',
    deviceId: 'cam1',
    attempt: 1,
    maxAttempts: 3,
  ),
  'heartbeatReconnected': const E.heartbeatReconnected(
    deviceType: 'camera',
    deviceId: 'cam1',
    afterAttempts: 1,
  ),
  'deviceDiscovered': const E.deviceDiscovered(
    deviceClass: 'camera',
    driver: 'zwo',
    id: 'cam2',
    name: 'ASI',
    displayName: 'ZWO ASI',
  ),
  'deviceLost': const E.deviceLost(
    deviceClass: 'camera',
    driver: 'zwo',
    id: 'cam2',
  ),
};

/// An event of another family under an equipment name.
final _guidingConnected = bridge.EventPayload.guiding(
  const bridge.GuidingEvent.connected(),
);

enum _Start { empty, devices }

void _seedDevices(ProviderContainer container) {
  for (final (type, id) in const [
    (DeviceType.camera, 'cam1'),
    (DeviceType.mount, 'mount1'),
    (DeviceType.focuser, 'foc1'),
    (DeviceType.filterWheel, 'fw1'),
    (DeviceType.rotator, 'rot1'),
  ]) {
    readDeviceConnectionNotifier(container, type)
      ..setConnecting(id, id)
      ..setConnected();
  }
}

final _clockTime = RegExp(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+');

String _slots(ProviderContainer container) => [
  'camera=${container.read(cameraStateProvider).props}',
  'mount=${container.read(mountStateProvider).props}',
  'focuser=${container.read(focuserStateProvider).props}',
  'wheel=${container.read(filterWheelStateProvider).props}',
  'rotator=${container.read(rotatorStateProvider).props}',
  'guider=${container.read(guiderStateProvider).props}',
].join(' ').replaceAll(_clockTime, 'now');

ProviderContainer _container(SkotiqBackend backend) => ProviderContainer(
  overrides: [
    inMemoryDatabaseOverride(),
    backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
    loggingServiceProvider.overrideWithValue(LoggingService()),
  ],
);

String _health(ProviderContainer container) => [
  for (final MapEntry(:key, :value)
      in container.read(deviceHeartbeatHealthProvider).entries)
    '$key:${value.health.name}/${value.reason}/${value.lastRttMs}/'
        '${value.consecutiveFailures}',
].join(',');

String _serviceReaction(_Start start, SkotiqEvent event) {
  late String result;
  fakeAsync((async) {
    final events = StreamController<SkotiqEvent>.broadcast();
    final backend = _RecordingBackend(events.stream);
    final container = _container(backend);
    try {
      container.read(deviceServiceProvider);
      if (start == _Start.devices) _seedDevices(container);
      async.elapse(const Duration(seconds: 1));
      final before = _slots(container);
      final health = _health(container);
      backend.calls.clear();

      events.add(event);
      async.flushMicrotasks();
      final after = _slots(container);
      final callsAtOnce = backend.calls.join(',');
      backend.calls.clear();
      async.elapse(const Duration(seconds: 5));
      final healthAfter = _health(container);
      result = [
        if (after == before) 'slots unchanged' else 'slots=$after',
        if (healthAfter != health) 'health=$healthAfter',
        'retained=${container.read(retainedCapturesRevisionProvider)}',
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

String _hostWindowReaction(_Start start, SkotiqEvent event) {
  final backend = _RecordingBackend(const Stream.empty());
  final container = _container(backend);
  try {
    if (start == _Start.devices) _seedDevices(container);
    final before = _slots(container);
    applyHostLocalSyncEvent(container, event);
    final after = _slots(container);
    return after == before ? 'slots unchanged' : 'slots=$after';
  } finally {
    container.dispose();
  }
}

/// The severity a producer sends an event at, where it is not info: a fault
/// is an error, a notice about a device that still works a warning.
const _severities = {
  'error camera': bridge.EventSeverity.error,
  'error camera warning': bridge.EventSeverity.warning,
};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final rows = <String, SkotiqEvent Function(EventPath)>{
    for (final entry in _equipment.entries)
      entry.key: (path) => wireEventOver(
        path,
        bridge.EventPayload.equipment(entry.value),
        severity: _severities[entry.key] ?? bridge.EventSeverity.info,
      ),
    'guiding Connected': (path) => wireEventOver(path, _guidingConnected),
  };

  for (final start in _Start.values) {
    test('device service reactions from ${start.name} slots', () {
      final table = <String, String>{};
      for (final row in rows.entries) {
        final ffi = _serviceReaction(start, row.value(EventPath.ffi));
        final network = _serviceReaction(start, row.value(EventPath.network));
        expect(network, ffi, reason: '${row.key}: the transports disagree');
        table[row.key] = ffi;
      }
      expect(table, _expected[start]);
    });

    test('host window reactions from ${start.name} slots', () {
      final table = <String, String>{};
      for (final row in rows.entries) {
        final ffi = _hostWindowReaction(start, row.value(EventPath.ffi));
        final network = _hostWindowReaction(
          start,
          row.value(EventPath.network),
        );
        expect(network, ffi, reason: '${row.key}: the transports disagree');
        table[row.key] = ffi;
      }
      expect(table, _hostWindowExpected[start]);
    });
  }
}

const Map<_Start, Map<String, String>> _expected = {
  _Start.empty: {
    'connecting camera':
        'slots=camera=[DeviceConnectionState.connecting, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.disconnected, null, null, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=',
    'connected camera':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.disconnected, null, null, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=',
    'connected mount':
        'slots=camera=[DeviceConnectionState.disconnected, null, null, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus',
    'disconnected camera':
        'slots unchanged health=cam1:reconnecting/Reconnecting (attempt 0)/null/0 retained=0 calls= later=',
    'disconnected other':
        'slots unchanged health=other:reconnecting/Reconnecting (attempt 0)/null/0 retained=0 calls= later=',
    'propertyChanged gain': 'slots unchanged retained=0 calls= later=',
    'propertyChanged device_change': 'slots unchanged retained=0 calls= later=',
    'propertyChanged AutofocusProgress':
        'slots unchanged retained=0 calls= later=',
    'propertyChanged FocuserBacklashCalibrationProgress':
        'slots unchanged retained=0 calls= later=',
    'error camera':
        'slots=camera=[DeviceConnectionState.error, null, null, null, null, -10.0, null, null, null, null, false, false, null, DeviceError(type: DeviceErrorType.unknown, message: USB gone, deviceId: null), null, true] mount=[DeviceConnectionState.disconnected, null, null, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=',
    'error camera warning': 'slots unchanged retained=0 calls= later=',
    'mountSlewStarted': 'slots unchanged retained=0 calls= later=',
    'mountSlewStarted other': 'slots unchanged retained=0 calls= later=',
    'mountSlewCompleted': 'slots unchanged retained=0 calls= later=',
    'mountTrackingStarted': 'slots unchanged retained=0 calls= later=',
    'mountTrackingStopped': 'slots unchanged retained=0 calls= later=',
    'mountParkStarted': 'slots unchanged retained=0 calls= later=',
    'mountParkCompleted': 'slots unchanged retained=0 calls= later=',
    'mountUnparked': 'slots unchanged retained=0 calls= later=',
    'focuserMoveStarted': 'slots unchanged retained=0 calls= later=',
    'focuserMoveCompleted': 'slots unchanged retained=0 calls= later=',
    'focuserMoveCompleted other': 'slots unchanged retained=0 calls= later=',
    'filterChanging': 'slots unchanged retained=0 calls= later=',
    'filterChanged': 'slots unchanged retained=0 calls= later=',
    'rotatorMoveStarted': 'slots unchanged retained=0 calls= later=',
    'rotatorMoveCompleted': 'slots unchanged retained=0 calls= later=',
    'cameraCoolingStarted': 'slots unchanged retained=0 calls= later=',
    'cameraCoolingReached': 'slots unchanged retained=0 calls= later=',
    'cameraWarmingStarted': 'slots unchanged retained=0 calls= later=',
    'cameraWarmingCompleted': 'slots unchanged retained=0 calls= later=',
    'cameraTemperatureChanged': 'slots unchanged retained=0 calls= later=',
    'cameraTemperatureChanged no power':
        'slots unchanged retained=0 calls= later=',
    'cameraSettingsChanged': 'slots unchanged retained=0 calls= later=',
    'cameraRetainedCapturesChanged': 'slots unchanged retained=1 calls= later=',
    'heartbeatStarted':
        'slots unchanged health=cam1:healthy/null/null/0 retained=0 calls= later=',
    'heartbeatStopped': 'slots unchanged retained=0 calls= later=',
    'heartbeatStatusChanged degraded':
        'slots unchanged health=cam1:degraded/2 consecutive heartbeat failures (last RTT 120ms)/120/2 retained=0 calls= later=',
    'heartbeatStatusChanged disconnected':
        'slots unchanged health=cam1:reconnecting/Reconnecting (attempt 0)/null/0 retained=0 calls= later=',
    'heartbeatReconnecting':
        'slots unchanged health=cam1:reconnecting/Reconnecting (attempt 1 of 3)/null/0 retained=0 calls= later=',
    'heartbeatReconnected':
        'slots unchanged health=cam1:healthy/Recovered after 1 attempt/null/0 retained=0 calls= later=',
    'deviceDiscovered': 'slots unchanged retained=0 calls= later=',
    'deviceLost': 'slots unchanged retained=0 calls= later=',
    'guiding Connected': 'slots unchanged retained=0 calls= later=',
  },
  _Start.devices: {
    'connecting camera':
        'slots=camera=[DeviceConnectionState.connecting, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'connected camera':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'connected mount':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus',
    'disconnected camera':
        'slots=camera=[DeviceConnectionState.disconnected, null, null, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] health=cam1:reconnecting/Reconnecting (attempt 0)/null/0 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'disconnected other':
        'slots unchanged health=other:reconnecting/Reconnecting (attempt 0)/null/0 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'propertyChanged gain':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'propertyChanged device_change':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'propertyChanged AutofocusProgress':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'propertyChanged FocuserBacklashCalibrationProgress':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'error camera':
        'slots=camera=[DeviceConnectionState.error, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, DeviceError(type: DeviceErrorType.unknown, message: USB gone, deviceId: cam1), null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'error camera warning':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'mountSlewStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, true, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus',
    'mountSlewStarted other':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'mountSlewCompleted':
        'slots unchanged retained=0 calls=getPlateSolverConfig later=getMountStatus,getMountStatus,getMountStatus',
    'mountTrackingStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, true, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'mountTrackingStopped':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'mountParkStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, true, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus,getMountStatus',
    'mountParkCompleted':
        'slots unchanged retained=0 calls=getPlateSolverConfig later=getMountStatus,getMountStatus,getMountStatus',
    'mountUnparked':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, false, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls=getPlateSolverConfig later=getMountStatus,getMountStatus,getMountStatus',
    'focuserMoveStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, true, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getFocuserStatus,getMountStatus',
    'focuserMoveCompleted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, 510, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'focuserMoveCompleted other':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'filterChanging':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], true, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'filterChanged':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, 2, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'rotatorMoveStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, true, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'rotatorMoveCompleted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, 91.5, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraCoolingStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, true, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraCoolingReached':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, -10.0, 0.0, -10.0, null, null, null, null, false, false, null, null, now, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraWarmingStarted':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, false, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraWarmingCompleted':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraTemperatureChanged':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, -5.5, 40.0, -10.0, null, null, null, null, false, false, null, null, now, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraTemperatureChanged no power':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, -5.5, null, -10.0, null, null, null, null, false, false, null, null, now, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraSettingsChanged':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, 100, 10, 2x2, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'cameraRetainedCapturesChanged':
        'slots unchanged retained=1 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'heartbeatStarted':
        'slots unchanged health=cam1:healthy/null/null/0 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'heartbeatStopped':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'heartbeatStatusChanged degraded':
        'slots unchanged health=cam1:degraded/2 consecutive heartbeat failures (last RTT 120ms)/120/2 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'heartbeatStatusChanged disconnected':
        'slots=camera=[DeviceConnectionState.disconnected, null, null, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true] health=cam1:reconnecting/Reconnecting (attempt 0)/null/0 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'heartbeatReconnecting':
        'slots unchanged health=cam1:reconnecting/Reconnecting (attempt 1 of 3)/null/0 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'heartbeatReconnected':
        'slots unchanged health=cam1:healthy/Recovered after 1 attempt/null/0 retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'deviceDiscovered':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'deviceLost':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
    'guiding Connected':
        'slots unchanged retained=0 calls= later=getMountStatus,getMountStatus,getMountStatus',
  },
};
const Map<_Start, Map<String, String>> _hostWindowExpected = {
  _Start.empty: {
    'connecting camera':
        'slots=camera=[DeviceConnectionState.connecting, cam1, Cam, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.disconnected, null, null, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true]',
    'connected camera':
        'slots=camera=[DeviceConnectionState.connected, cam1, Cam, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.disconnected, null, null, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true]',
    'connected mount':
        'slots=camera=[DeviceConnectionState.disconnected, null, null, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, Mount, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true]',
    'disconnected camera': 'slots unchanged',
    'disconnected other': 'slots unchanged',
    'propertyChanged gain': 'slots unchanged',
    'propertyChanged device_change': 'slots unchanged',
    'propertyChanged AutofocusProgress': 'slots unchanged',
    'propertyChanged FocuserBacklashCalibrationProgress': 'slots unchanged',
    'error camera': 'slots unchanged',
    'error camera warning': 'slots unchanged',
    'mountSlewStarted': 'slots unchanged',
    'mountSlewStarted other': 'slots unchanged',
    'mountSlewCompleted': 'slots unchanged',
    'mountTrackingStarted': 'slots unchanged',
    'mountTrackingStopped': 'slots unchanged',
    'mountParkStarted': 'slots unchanged',
    'mountParkCompleted': 'slots unchanged',
    'mountUnparked': 'slots unchanged',
    'focuserMoveStarted': 'slots unchanged',
    'focuserMoveCompleted': 'slots unchanged',
    'focuserMoveCompleted other': 'slots unchanged',
    'filterChanging': 'slots unchanged',
    'filterChanged': 'slots unchanged',
    'rotatorMoveStarted': 'slots unchanged',
    'rotatorMoveCompleted': 'slots unchanged',
    'cameraCoolingStarted': 'slots unchanged',
    'cameraCoolingReached': 'slots unchanged',
    'cameraWarmingStarted': 'slots unchanged',
    'cameraWarmingCompleted': 'slots unchanged',
    'cameraTemperatureChanged': 'slots unchanged',
    'cameraTemperatureChanged no power': 'slots unchanged',
    'cameraSettingsChanged': 'slots unchanged',
    'cameraRetainedCapturesChanged': 'slots unchanged',
    'heartbeatStarted': 'slots unchanged',
    'heartbeatStopped': 'slots unchanged',
    'heartbeatStatusChanged degraded': 'slots unchanged',
    'heartbeatStatusChanged disconnected': 'slots unchanged',
    'heartbeatReconnecting': 'slots unchanged',
    'heartbeatReconnected': 'slots unchanged',
    'deviceDiscovered': 'slots unchanged',
    'deviceLost': 'slots unchanged',
    'guiding Connected':
        'slots=camera=[DeviceConnectionState.disconnected, null, null, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.disconnected, null, null, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.disconnected, null, null, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.disconnected, null, null, null, [], false, null, true] rotator=[DeviceConnectionState.disconnected, null, null, null, null, false, false, null, true] guider=[DeviceConnectionState.connected, phd2_guider, PHD2 Guiding, false, false, null, null, null, null, null, true]',
  },
  _Start.devices: {
    'connecting camera': 'slots unchanged',
    'connected camera': 'slots unchanged',
    'connected mount': 'slots unchanged',
    'disconnected camera':
        'slots=camera=[DeviceConnectionState.disconnected, null, null, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.disconnected, null, null, false, false, null, null, null, null, null, true]',
    'disconnected other': 'slots unchanged',
    'propertyChanged gain': 'slots unchanged',
    'propertyChanged device_change': 'slots unchanged',
    'propertyChanged AutofocusProgress': 'slots unchanged',
    'propertyChanged FocuserBacklashCalibrationProgress': 'slots unchanged',
    'error camera': 'slots unchanged',
    'error camera warning': 'slots unchanged',
    'mountSlewStarted': 'slots unchanged',
    'mountSlewStarted other': 'slots unchanged',
    'mountSlewCompleted': 'slots unchanged',
    'mountTrackingStarted': 'slots unchanged',
    'mountTrackingStopped': 'slots unchanged',
    'mountParkStarted': 'slots unchanged',
    'mountParkCompleted': 'slots unchanged',
    'mountUnparked': 'slots unchanged',
    'focuserMoveStarted': 'slots unchanged',
    'focuserMoveCompleted': 'slots unchanged',
    'focuserMoveCompleted other': 'slots unchanged',
    'filterChanging': 'slots unchanged',
    'filterChanged': 'slots unchanged',
    'rotatorMoveStarted': 'slots unchanged',
    'rotatorMoveCompleted': 'slots unchanged',
    'cameraCoolingStarted': 'slots unchanged',
    'cameraCoolingReached': 'slots unchanged',
    'cameraWarmingStarted': 'slots unchanged',
    'cameraWarmingCompleted': 'slots unchanged',
    'cameraTemperatureChanged': 'slots unchanged',
    'cameraTemperatureChanged no power': 'slots unchanged',
    'cameraSettingsChanged': 'slots unchanged',
    'cameraRetainedCapturesChanged': 'slots unchanged',
    'heartbeatStarted': 'slots unchanged',
    'heartbeatStopped': 'slots unchanged',
    'heartbeatStatusChanged degraded': 'slots unchanged',
    'heartbeatStatusChanged disconnected': 'slots unchanged',
    'heartbeatReconnecting': 'slots unchanged',
    'heartbeatReconnected': 'slots unchanged',
    'deviceDiscovered': 'slots unchanged',
    'deviceLost': 'slots unchanged',
    'guiding Connected':
        'slots=camera=[DeviceConnectionState.connected, cam1, cam1, null, null, -10.0, null, null, null, null, false, false, null, null, null, true] mount=[DeviceConnectionState.connected, mount1, mount1, null, null, null, null, false, false, true, false, false, false, null, null, false, true, null, true] focuser=[DeviceConnectionState.connected, foc1, foc1, null, null, null, false, false, null, false, null, true] wheel=[DeviceConnectionState.connected, fw1, fw1, null, [], false, null, true] rotator=[DeviceConnectionState.connected, rot1, rot1, null, null, false, false, null, true] guider=[DeviceConnectionState.connected, phd2_guider, PHD2 Guiding, false, false, null, null, null, null, null, true]',
  },
};
