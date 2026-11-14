// Overview's "Equipment" block: one row per imaging device.
//
// A connected device shows its live readouts. One that is not connected
// shows no readouts at all, because a stale number beside a dead device is
// the easiest lie this block could tell; a device the profile assigns says
// "not connected", one it does not reads "none", and one in error says why.
// A connected device whose reads are failing keeps its last readouts but
// leads with how old they are, so they are never read as current. Power has
// no telemetry in the app, so the board's Power row is left out.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../night_control_contracts.dart';
import 'session_format.dart';

/// PHD2 states in which the guider is doing useful work.
const Set<Phd2State> _guiderWorking = <Phd2State>{
  Phd2State.guiding,
  Phd2State.looping,
  Phd2State.calibrating,
  Phd2State.settling,
};

/// The translations key for a PHD2 state word.
String nightPhd2StateKey(Phd2State state) => switch (state) {
      Phd2State.guiding => 'nightSessionGuiderGuiding',
      Phd2State.looping => 'nightSessionGuiderLooping',
      Phd2State.calibrating => 'nightSessionGuiderCalibrating',
      Phd2State.settling => 'nightSessionGuiderSettling',
      Phd2State.paused => 'nightSessionGuiderPaused',
      Phd2State.lostLock => 'nightSessionGuiderLostStar',
      Phd2State.selected => 'nightSessionGuiderStarSelected',
      Phd2State.stopped => 'nightSessionGuiderNotLooping',
      Phd2State.unknown => 'nightSessionGuiderUnknown',
    };

/// The guider stop reasons the app has words for (`nightScopeGuideHeld_*`),
/// as the guider status names them.
const Set<String> kNightGuideStopReasons = <String>{
  'autofocus',
  'meridian_flip',
  'tracking_limit_hold',
  'mount_move',
  'pre_meridian_hold',
  'sequence_step',
  'dither_settle',
  'run_stopped',
  'operator',
};

/// Why the guider is stopped or held, in the guide tab's words.
NightText nightGuideStopReason(String reason) =>
    kNightGuideStopReasons.contains(reason)
        ? NightText('nightScopeGuideHeld_$reason')
        : NightText(
            'nightScopeGuideHeldOther',
            params: <String, String>{'reason': reason},
          );

/// The translations key for a reported side of pier, or null when the mount
/// reports something else.
String? nightPierKey(String? side) => switch (side?.trim().toLowerCase()) {
      'east' || 'pierside_east' => 'nightSessionPierEast',
      'west' || 'pierside_west' => 'nightSessionPierWest',
      _ => null,
    };

/// The lead detail of a connected device whose readouts are stale: how old
/// they are and why.
NightText nightStaleText(StaleReadings stale, DateTime now) {
  final age = stale.ageAt(now);
  final reason = stale.reason?.trim();
  return NightText(
    age == null ? 'nightSessionStaleNoRead' : 'nightSessionStale',
    params: <String, String>{
      if (age != null) 'age': staleAgeText(age),
      'reason': reason == null || reason.isEmpty ? '' : ': $reason',
    },
  );
}

/// The dot for a device that is not plainly connected, with the reason.
EquipmentRowVm _notConnected(
  EquipmentKind kind,
  DeviceConnectionState state,
  String? name, {
  required bool assigned,
  DeviceError? error,
}) {
  switch (state) {
    case DeviceConnectionState.error:
      final reason = error?.message.trim();
      return EquipmentRowVm(
        kind: kind,
        status: EquipmentStatus.fault,
        deviceName: name,
        details: <NightText>[
          const NightText('nightSessionDeviceFault'),
          if (reason != null && reason.isNotEmpty) NightText.literal(reason),
        ],
      );
    case DeviceConnectionState.connecting:
      return EquipmentRowVm(
        kind: kind,
        status: EquipmentStatus.attention,
        deviceName: name,
        details: const <NightText>[NightText('nightSessionDeviceConnecting')],
      );
    case DeviceConnectionState.connected:
    case DeviceConnectionState.disconnected:
      return EquipmentRowVm(
        kind: kind,
        status: EquipmentStatus.absent,
        deviceName: assigned ? name : null,
        details: assigned
            ? const <NightText>[NightText('nightSessionDeviceNotConnected')]
            : const <NightText>[],
      );
  }
}

/// What one device slot's row shows of its state.
///
/// Rows read a device through a select of this, not its whole state: a whole
/// state changes with every telemetry poll, and each recompute of the rows
/// costs a frame even when no row changes.
@immutable
class _SlotFacts {
  _SlotFacts(DeviceSlotState<Object?> state, [this.details = const []])
      : connectionState = state.connectionState,
        name = state.deviceName,
        deviceId = state.deviceId,
        error = state.lastError;

  const _SlotFacts._(
    this.connectionState,
    this.name,
    this.deviceId,
    this.error,
    this.details,
  );

  _SlotFacts withDetails(List<NightText> details) =>
      _SlotFacts._(connectionState, name, deviceId, error, details);

  final DeviceConnectionState connectionState;
  final String? name;
  final String? deviceId;
  final DeviceError? error;
  final List<NightText> details;

  @override
  bool operator ==(Object other) =>
      other is _SlotFacts &&
      other.connectionState == connectionState &&
      other.name == name &&
      other.deviceId == deviceId &&
      other.error == error &&
      listEquals(other.details, details);

  @override
  int get hashCode => Object.hash(
        connectionState,
        name,
        deviceId,
        error,
        Object.hashAll(details),
      );
}

_SlotFacts _cameraFacts(
  CameraStateSnapshot camera,
  ExposureSensitivity sensitivity,
) {
  final temp = camera.temperature;
  final cooling = camera.isCooling &&
      temp != null &&
      (temp - camera.targetTemp).abs() >= 0.5;
  final gain = camera.gain;
  final offset = camera.offset;
  final binning = camera.binning;
  return _SlotFacts(camera, <NightText>[
    if (temp != null)
      // A word, not an arrow: the mono face this row is set in has no arrow
      // glyph.
      cooling
          ? NightText(
              'nightScrCoolingTo',
              params: <String, String>{
                'temp': nightCelsius(temp),
                'target': nightFixed(camera.targetTemp, 0),
              },
            )
          : NightText.literal(nightCelsius(temp)),
    if (camera.coolerPower != null)
      NightText.literal('${camera.coolerPower!.round()}%'),
    if (gain != null || (offset != null && sensitivity.hasOffset))
      NightText.literal(
        [
          if (gain != null) sensitivity.abbreviate(gain),
          if (offset != null && sensitivity.hasOffset) 'o$offset',
        ].join(' '),
      ),
    if (binning != null && binning.isNotEmpty)
      NightText.literal(binning.replaceAll(RegExp('[xX]'), '×')),
  ]);
}

_SlotFacts _wheelFacts(FilterWheelState wheel) {
  final slot = wheel.currentPosition;
  if (slot == null) return _SlotFacts(wheel);
  final names = wheel.filterNames;
  // Positions are zero-based on the wire and one-based to the operator.
  final name = slot >= 0 && slot < names.length ? names[slot] : null;
  return _SlotFacts(wheel, <NightText>[
    NightText(
      name == null || name.isEmpty
          ? 'nightSessionFilterSlotOnly'
          : 'nightSessionFilterSlot',
      params: <String, String>{
        if (name != null) 'name': name,
        'slot': '${slot + 1}',
        'count': '${names.length}',
      },
    ),
  ]);
}

_SlotFacts _focuserFacts(FocuserState focuser) =>
    _SlotFacts(focuser, <NightText>[
      if (focuser.position != null) nightFocuserSteps(focuser.position!),
      if (focuser.temperature != null)
        NightText.literal(nightCelsius(focuser.temperature!)),
      if (focuser.isMoving) const NightText('nightSessionFocuserMoving'),
    ]);

_SlotFacts _mountFacts(MountState mount) {
  final pier = nightPierKey(mount.sideOfPier);
  return _SlotFacts(mount, <NightText>[
    NightText(
      mount.isSlewing
          ? 'nightSessionMountSlewing'
          : mount.isParked
              ? 'nightSessionMountParked'
              : mount.isTracking
                  ? 'nightSessionMountTracking'
                  : 'nightSessionMountNotTracking',
    ),
    if (pier != null) NightText(pier),
    if (mount.altitude != null)
      NightText(
        'nightSessionMountAltitude',
        params: <String, String>{'alt': nightFixed(mount.altitude!, 1)},
      ),
  ]);
}

_SlotFacts _rotatorFacts(RotatorState rotator) =>
    _SlotFacts(rotator, <NightText>[
      if (rotator.position != null)
        NightText.literal('${nightFixed(rotator.position!, 1)}°'),
      if (rotator.isMoving) const NightText('nightSessionRotatorMoving'),
    ]);

final nightEquipmentProvider = Provider<List<EquipmentRowVm>>((ref) {
  final sensitivity = ref.watch(cameraSensitivityProvider);
  final camera = ref.watch(
    cameraStateProvider.select((c) => _cameraFacts(c, sensitivity)),
  );
  final wheel = ref.watch(filterWheelStateProvider.select(_wheelFacts));
  final focuser = ref.watch(focuserStateProvider.select(_focuserFacts));
  final mount = ref.watch(mountStateProvider.select(_mountFacts));
  final guider = ref.watch(guiderStateProvider.select(_SlotFacts.new));
  final rotator = ref.watch(rotatorStateProvider.select(_rotatorFacts));
  final phd2 = ref.watch(phd2StateProvider);
  final guideStats = ref.watch(guideStatsProvider);
  final guideStopReason = ref.watch(guidingStopReasonProvider);
  final assigned = ref.watch(rigDevicesProvider).assigned.toSet();
  final reads = ref.watch(deviceReadHealthProvider);
  final heartbeats = ref.watch(deviceHeartbeatHealthProvider);
  final now = DateTime.now();

  EquipmentRowVm row(
    EquipmentKind kind,
    DeviceType type,
    _SlotFacts facts, {
    EquipmentStatus connectedStatus = EquipmentStatus.ok,
  }) {
    if (!nightConnected(facts.connectionState)) {
      return _notConnected(
        kind,
        facts.connectionState,
        facts.name,
        assigned: assigned.contains(type),
        error: facts.error,
      );
    }
    final stale = staleReadingsFor(reads, heartbeats, type, facts.deviceId);
    if (stale != null) {
      // Keeps the age beside stale readouts counting; only while one is
      // shown, so an idle Tonight holds no timer.
      ref.watch(staleAgeTickerProvider);
      return EquipmentRowVm(
        kind: kind,
        status: EquipmentStatus.attention,
        deviceName: facts.name,
        details: <NightText>[nightStaleText(stale, now), ...facts.details],
      );
    }
    return EquipmentRowVm(
      kind: kind,
      status: connectedStatus,
      deviceName: facts.name,
      details: facts.details,
    );
  }

  // A held guider says why (an autofocus, a flip, the mount's tracking
  // limit) rather than only "not looping".
  final mass = guideStats.frameCount > 0 && guideStats.starMass > 0
      ? guideStats.starMass
      : null;
  final held = !_guiderWorking.contains(phd2) &&
          guideStopReason != null &&
          guideStopReason.isNotEmpty
      ? guideStopReason
      : null;
  final guiderDetails = <NightText>[
    if (held != null)
      nightGuideStopReason(held)
    else
      NightText(nightPhd2StateKey(phd2)),
    if (mass != null)
      NightText(
        'nightSessionGuiderMass',
        params: <String, String>{
          'mass': mass >= 1000
              ? '${(mass / 1000).toStringAsFixed(1)}k'
              : mass.round().toString(),
        },
      ),
  ];

  return <EquipmentRowVm>[
    row(EquipmentKind.camera, DeviceType.camera, camera),
    row(EquipmentKind.filterWheel, DeviceType.filterWheel, wheel),
    row(EquipmentKind.focuser, DeviceType.focuser, focuser),
    row(EquipmentKind.mount, DeviceType.mount, mount),
    row(
      EquipmentKind.guider,
      DeviceType.guider,
      // The guider's state carries no readouts; its words come from the
      // guiding service.
      guider.withDetails(guiderDetails),
      connectedStatus: _guiderWorking.contains(phd2)
          ? EquipmentStatus.ok
          : EquipmentStatus.attention,
    ),
    row(EquipmentKind.rotator, DeviceType.rotator, rotator),
  ];
});
