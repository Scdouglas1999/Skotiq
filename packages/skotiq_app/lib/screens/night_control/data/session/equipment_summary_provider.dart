// Overview's "Equipment" block: one row per imaging device.
//
// A connected device shows its live readouts. One that is not connected
// shows no readouts at all, because a stale number beside a dead device is
// the easiest lie this block could tell; a device the profile assigns says
// "not connected", one it does not reads "none", and one in error says why.
// A connected device whose reads are failing keeps its last readouts but
// leads with how old they are, so they are never read as current. Power has
// no telemetry in the app, so the board's Power row is left out.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide EquipmentStatus;

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

final nightEquipmentProvider = Provider<List<EquipmentRowVm>>((ref) {
  final camera = ref.watch(cameraStateProvider);
  final wheel = ref.watch(filterWheelStateProvider);
  final focuser = ref.watch(focuserStateProvider);
  final mount = ref.watch(mountStateProvider);
  final guider = ref.watch(guiderStateProvider);
  final rotator = ref.watch(rotatorStateProvider);
  final phd2 = ref.watch(phd2StateProvider);
  final guideStats = ref.watch(guideStatsProvider);
  final guideStopReason = ref.watch(guidingStopReasonProvider);
  final assigned = ref.watch(assignedProfileDeviceSlotsProvider).toSet();
  final reads = ref.watch(deviceReadHealthProvider);
  final heartbeats = ref.watch(deviceHeartbeatHealthProvider);
  // Keeps the age beside stale readouts counting.
  ref.watch(staleAgeTickerProvider);
  final now = DateTime.now();

  EquipmentRowVm row(
    EquipmentKind kind,
    ProfileDeviceSlot slot,
    DeviceConnectionState state,
    String? name,
    List<NightText> Function() details, {
    EquipmentStatus connectedStatus = EquipmentStatus.ok,
    DeviceType? type,
    String? deviceId,
    DeviceError? error,
  }) {
    if (!nightConnected(state)) {
      return _notConnected(
        kind,
        state,
        name,
        assigned: assigned.contains(slot),
        error: error,
      );
    }
    final stale = type == null
        ? null
        : staleReadingsFor(reads, heartbeats, type, deviceId);
    if (stale != null) {
      return EquipmentRowVm(
        kind: kind,
        status: EquipmentStatus.attention,
        deviceName: name,
        details: <NightText>[nightStaleText(stale, now), ...details()],
      );
    }
    return EquipmentRowVm(
      kind: kind,
      status: connectedStatus,
      deviceName: name,
      details: details(),
    );
  }

  return <EquipmentRowVm>[
    row(
      EquipmentKind.camera,
      ProfileDeviceSlot.camera,
      camera.connectionState,
      camera.deviceName,
      () {
        final temp = camera.temperature;
        final cooling = camera.isCooling &&
            temp != null &&
            (temp - camera.targetTemp).abs() >= 0.5;
        final gain = camera.gain;
        final offset = camera.offset;
        final binning = camera.binning;
        return <NightText>[
          if (temp != null)
            // A word, not an arrow: the mono face this row is set in has no
            // arrow glyph.
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
          if (gain != null || offset != null)
            NightText.literal(
              [
                if (gain != null) 'g$gain',
                if (offset != null) 'o$offset',
              ].join(' '),
            ),
          if (binning != null && binning.isNotEmpty)
            NightText.literal(binning.replaceAll(RegExp('[xX]'), '×')),
        ];
      },
      type: DeviceType.camera,
      deviceId: camera.deviceId,
      error: camera.lastError,
    ),
    row(
      EquipmentKind.filterWheel,
      ProfileDeviceSlot.filterWheel,
      wheel.connectionState,
      wheel.deviceName,
      () {
        final slot = wheel.currentPosition;
        if (slot == null) return const <NightText>[];
        final names = wheel.filterNames;
        // Positions are zero-based on the wire and one-based to the operator.
        final name = slot >= 0 && slot < names.length ? names[slot] : null;
        return <NightText>[
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
        ];
      },
      type: DeviceType.filterWheel,
      deviceId: wheel.deviceId,
      error: wheel.lastError,
    ),
    row(
      EquipmentKind.focuser,
      ProfileDeviceSlot.focuser,
      focuser.connectionState,
      focuser.deviceName,
      () => <NightText>[
        if (focuser.position != null)
          NightText.literal(nightGrouped(focuser.position!)),
        if (focuser.temperature != null)
          NightText.literal(nightCelsius(focuser.temperature!)),
        if (focuser.isMoving) const NightText('nightSessionFocuserMoving'),
      ],
      type: DeviceType.focuser,
      deviceId: focuser.deviceId,
      error: focuser.lastError,
    ),
    row(
      EquipmentKind.mount,
      ProfileDeviceSlot.mount,
      mount.connectionState,
      mount.deviceName,
      () {
        final pier = nightPierKey(mount.sideOfPier);
        return <NightText>[
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
              params: <String, String>{
                'alt': nightFixed(mount.altitude!, 1),
              },
            ),
        ];
      },
      type: DeviceType.mount,
      deviceId: mount.deviceId,
      error: mount.lastError,
    ),
    row(
      EquipmentKind.guider,
      ProfileDeviceSlot.guider,
      guider.connectionState,
      guider.deviceName,
      () {
        final mass = guideStats.frameCount > 0 && guideStats.starMass > 0
            ? guideStats.starMass
            : null;
        // A held guider says why (an autofocus, a flip, the mount's
        // tracking limit) rather than only "not looping".
        final held = !_guiderWorking.contains(phd2) &&
                guideStopReason != null &&
                guideStopReason.isNotEmpty
            ? guideStopReason
            : null;
        return <NightText>[
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
      },
      connectedStatus: _guiderWorking.contains(phd2)
          ? EquipmentStatus.ok
          : EquipmentStatus.attention,
      type: DeviceType.guider,
      deviceId: guider.deviceId,
      error: guider.lastError,
    ),
    row(
      EquipmentKind.rotator,
      ProfileDeviceSlot.rotator,
      rotator.connectionState,
      rotator.deviceName,
      () => <NightText>[
        if (rotator.position != null)
          NightText.literal('${nightFixed(rotator.position!, 1)}°'),
        if (rotator.isMoving) const NightText('nightSessionRotatorMoving'),
      ],
      type: DeviceType.rotator,
      deviceId: rotator.deviceId,
      error: rotator.lastError,
    ),
  ];
});
