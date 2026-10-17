import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../utils/device_id.dart';
import '../profiles_provider.dart';
import 'camera_state_provider.dart';
import 'cover_calibrator_state_provider.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'focuser_state_provider.dart';
import 'guider_state_provider.dart';
import 'mount_state_provider.dart';
import 'rotator_state_provider.dart';
import 'safety_monitor_state_provider.dart';
import 'switch_state_provider.dart';
import 'weather_state_provider.dart';

/// The device slots a profile can assign, in canonical display order.
///
/// The first six (camera → rotator) are the "core" imaging-chain devices that
/// the profile sidebar surfaces as connection dots and a `connected/total`
/// count. The remaining five (dome → cover calibrator) are auxiliary devices
/// that only participate in the equipment-screen mismatch banner. [isCore]
/// distinguishes the two groups so each consumer reads the rollup it needs.
enum ProfileDeviceSlot {
  camera('Camera', isCore: true),
  mount('Mount', isCore: true),
  focuser('Focuser', isCore: true),
  filterWheel('Filter Wheel', isCore: true),
  guider('Guider', isCore: true),
  rotator('Rotator', isCore: true),
  dome('Dome', isCore: false),
  weather('Weather Station', isCore: false),
  safetyMonitor('Safety Monitor', isCore: false),
  switchDevice('Switch', isCore: false),
  coverCalibrator('Cover Calibrator', isCore: false);

  const ProfileDeviceSlot(this.displayName, {required this.isCore});

  /// The human-readable device label used by the sidebar tooltip and the
  /// mismatch banner's device list.
  final String displayName;

  /// Whether this slot is part of the imaging-chain "core" set surfaced by the
  /// profile sidebar (dots + `connected/total`). Auxiliary slots are
  /// `false` and only feed the mismatch banner.
  final bool isCore;
}

/// The computed status of a single device slot for one profile.
///
/// This is the per-cell of the "is device X connected for profile Y" matrix.
/// Every id comparison routes through `device_id.dart` (canonical PHD2
/// collapse + the legacy fuzzy fallback); nothing here re-implements matching.
class ProfileDeviceConnection {
  const ProfileDeviceConnection({
    required this.slot,
    required this.profileId,
    required this.connectedId,
    required this.connectedState,
  });

  final ProfileDeviceSlot slot;

  /// The device id the profile assigned to this slot, or `null` if the slot is
  /// unassigned.
  final String? profileId;

  /// The id of the device actually connected in this slot's state provider, or
  /// `null` if nothing is connected.
  final String? connectedId;

  /// The raw connection state of the device occupying this slot, regardless of
  /// whether it matches the profile assignment.
  final DeviceConnectionState connectedState;

  /// Whether the profile assigns any device to this slot.
  bool get isAssigned => profileId != null;

  /// Whether the connected device is the one the profile assigned, using the
  /// canonical fuzzy + PHD2-collapse matcher ([deviceIdsMatch]).
  ///
  /// A connected device whose id drifted in format still counts as the
  /// assigned device.
  bool get matchesProfile {
    final pid = profileId;
    final cid = connectedId;
    if (pid == null || cid == null) return false;
    if (connectedState == DeviceConnectionState.disconnected) return false;
    return deviceIdsMatch(pid, cid);
  }

  /// The connection state of this slot *as seen by the profile* — exactly the
  /// value the sidebar's `_getDeviceConnectionState` returned.
  ///
  /// Unassigned slots are not represented here (the matrix omits them). For an
  /// assigned slot: if nothing matches, the slot reads as `disconnected`;
  /// otherwise it reads the live connection state of the matched device.
  DeviceConnectionState get profileState {
    if (!isAssigned) return DeviceConnectionState.disconnected;
    final cid = connectedId;
    if (cid == null || connectedState == DeviceConnectionState.disconnected) {
      return DeviceConnectionState.disconnected;
    }
    if (deviceIdsMatch(profileId!, cid)) {
      return connectedState;
    }
    return DeviceConnectionState.disconnected;
  }

  /// Whether this slot is a *mismatch* for the equipment-screen banner.
  ///
  /// The banner uses a deliberately stricter rule than the sidebar: a slot is a
  /// mismatch only when BOTH a device is connected (non-empty id) AND the
  /// profile assigns one (non-empty id) AND the two ids differ after the
  /// PHD2-canonical collapse. It does NOT use the fuzzy token matcher — a fuzzy
  /// (but not canonical-equal) pairing is reported as a mismatch, exactly as
  /// the old inline `check(...)` did. The guider applies [canonicalGuiderId]
  /// to both sides so the same PHD2 guider recorded under any of its
  /// representations is never flagged.
  bool get isMismatch {
    final pid = profileId;
    final cid = connectedId;
    if (pid == null || pid.isEmpty) return false;
    if (cid == null || cid.isEmpty) return false;
    if (slot == ProfileDeviceSlot.guider) {
      return canonicalGuiderId(cid) != canonicalGuiderId(pid);
    }
    return cid != pid;
  }
}

/// The full per-profile connection matrix plus the rollups every consumer
/// needs. This is the single source of truth that replaces the duplicated
/// derivations in `profile_sidebar` and `equipment_screen`.
class ProfileConnectionStatus {
  const ProfileConnectionStatus({
    required this.profileId,
    required this.connections,
  });

  /// The profile id this status was computed for (may be `null` for an
  /// unsaved profile). Carried so consumers can assert they are reading the
  /// status they expect.
  final int? profileId;

  /// One entry per [ProfileDeviceSlot], in declaration order.
  final List<ProfileDeviceConnection> connections;

  ProfileDeviceConnection operator [](ProfileDeviceSlot slot) =>
      connections.firstWhere((c) => c.slot == slot);

  // Sidebar rollups (core slots only)

  /// Number of assigned core slots (the denominator of the sidebar's
  /// `connected/total` badge).
  int get coreTotalCount =>
      connections.where((c) => c.slot.isCore && c.isAssigned).length;

  /// Number of assigned core slots whose matched device is `connected` (the
  /// numerator of the sidebar badge).
  int get coreConnectedCount => connections
      .where(
        (c) =>
            c.slot.isCore &&
            c.isAssigned &&
            c.profileState == DeviceConnectionState.connected,
      )
      .length;

  /// Whether any assigned core slot currently matches a `connected` device.
  /// Drives the sidebar footer's "Disconnect All" affordance.
  bool get hasConnectedCore => connections.any(
    (c) =>
        c.slot.isCore &&
        c.isAssigned &&
        c.profileState == DeviceConnectionState.connected,
  );

  /// Whether any assigned core slot is not currently a matched, `connected`
  /// device. Drives the sidebar footer's "Connect All" affordance.
  ///
  /// An assigned slot that is connecting, errored, mismatched, or absent all
  /// count as "disconnected" for the purpose of offering Connect All.
  bool get hasDisconnectedCore => connections.any(
    (c) =>
        c.slot.isCore &&
        c.isAssigned &&
        c.profileState != DeviceConnectionState.connected,
  );

  /// The per-slot `profileState` for every assigned core slot, in display
  /// order. Used to build the sidebar's connection dots.
  Map<ProfileDeviceSlot, DeviceConnectionState> get coreSlotStates => {
    for (final c in connections)
      if (c.slot.isCore && c.isAssigned) c.slot: c.profileState,
  };

  // Banner rollups (all slots)

  /// The display names of every slot flagged as a mismatch by the banner
  /// rule, in [ProfileDeviceSlot] declaration order.
  List<String> get mismatchedDeviceNames => connections
      .where((c) => c.isMismatch)
      .map((c) => c.slot.displayName)
      .toList(growable: false);

  /// Whether any slot is a mismatch (banner rule).
  bool get hasMismatch => connections.any((c) => c.isMismatch);
}

/// Canonical "is device X connected for profile Y" provider.
///
/// Watches every per-device state provider and computes a single
/// [ProfileConnectionStatus] for the supplied profile. All id comparison goes
/// through `device_id.dart`. This is the ONE place the connection matrix is
/// derived; the profile sidebar (dots + footer) and the equipment screen
/// (mismatch banner) both read from here instead of re-deriving it.
///
/// Keyed by [EquipmentProfileModel] so callers that already hold the profile
/// (the sidebar iterates the profile list) can read per-profile status without
/// a separate id→profile lookup. The family equality is the profile's
/// value-equality, so the same profile produces the same provider instance.
final profileConnectionStatusProvider =
    Provider.family<ProfileConnectionStatus, EquipmentProfileModel>((
      ref,
      profile,
    ) {
      final camera = ref.watch(cameraStateProvider);
      final mount = ref.watch(mountStateProvider);
      final focuser = ref.watch(focuserStateProvider);
      final filterWheel = ref.watch(filterWheelStateProvider);
      final guider = ref.watch(guiderStateProvider);
      final rotator = ref.watch(rotatorStateProvider);
      final dome = ref.watch(domeStateProvider);
      final weather = ref.watch(weatherStateProvider);
      final safetyMonitor = ref.watch(safetyMonitorStateProvider);
      final switchDevice = ref.watch(switchStateProvider);
      final coverCalibrator = ref.watch(coverCalibratorStateProvider);

      final connections = <ProfileDeviceConnection>[
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.camera,
          profileId: profile.cameraId,
          connectedId: camera.deviceId,
          connectedState: camera.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.mount,
          profileId: profile.mountId,
          connectedId: mount.deviceId,
          connectedState: mount.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.focuser,
          profileId: profile.focuserId,
          connectedId: focuser.deviceId,
          connectedState: focuser.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.filterWheel,
          profileId: profile.filterWheelId,
          connectedId: filterWheel.deviceId,
          connectedState: filterWheel.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.guider,
          profileId: profile.guiderId,
          connectedId: guider.deviceId,
          connectedState: guider.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.rotator,
          profileId: profile.rotatorId,
          connectedId: rotator.deviceId,
          connectedState: rotator.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.dome,
          profileId: profile.domeId,
          connectedId: dome.deviceId,
          connectedState: dome.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.weather,
          profileId: profile.weatherId,
          connectedId: weather.deviceId,
          connectedState: weather.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.safetyMonitor,
          profileId: profile.safetyMonitorId,
          connectedId: safetyMonitor.deviceId,
          connectedState: safetyMonitor.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.switchDevice,
          profileId: profile.switchId,
          connectedId: switchDevice.deviceId,
          connectedState: switchDevice.connectionState,
        ),
        ProfileDeviceConnection(
          slot: ProfileDeviceSlot.coverCalibrator,
          profileId: profile.coverCalibratorId,
          connectedId: coverCalibrator.deviceId,
          connectedState: coverCalibrator.connectionState,
        ),
      ];

      return ProfileConnectionStatus(
        profileId: profile.id,
        connections: connections,
      );
    });

/// Slots holding a device that is CONNECTED but that the active profile does not
/// assign — i.e. an ad-hoc connection made from the Discovery panel.
///
/// These connections are session-only: nothing writes them to
/// `equipment_profiles`, so the next launch reconnects only the profile devices
/// and the rest are gone without notice — which the operator cannot see from a
/// card that renders identically to a profile device.
///
/// Empty when there is no active profile: "no equipment profile is set up yet"
/// is already a BLOCKED readiness item, and repeating it per device card would
/// be noise. This answers the narrower question of which devices the operator
/// connected *outside* the profile they are running.
final sessionOnlyConnectedSlotsProvider = Provider<Set<ProfileDeviceSlot>>((
  ref,
) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return const <ProfileDeviceSlot>{};
  final status = ref.watch(profileConnectionStatusProvider(profile));
  return <ProfileDeviceSlot>{
    for (final connection in status.connections)
      if (connection.connectedState == DeviceConnectionState.connected &&
          !connection.matchesProfile)
        connection.slot,
  };
});

/// The ACTIVE profile's assigned device slots, in canonical slot order.
///
/// Distinct from [offlineProfileDeviceNamesProvider], which reports only the
/// assigned slots that are DOWN: an empty offline list cannot tell "every
/// assigned device is connected" apart from "this profile assigns no device",
/// and readiness must not read the second as a green row.
///
/// Empty when there is no active profile.
final assignedProfileDeviceSlotsProvider = Provider<List<ProfileDeviceSlot>>((
  ref,
) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return const <ProfileDeviceSlot>[];
  final status = ref.watch(profileConnectionStatusProvider(profile));
  return <ProfileDeviceSlot>[
    for (final connection in status.connections)
      if (connection.isAssigned) connection.slot,
  ];
});

/// Display names of the ACTIVE profile's assigned device slots that are not
/// currently connected, in canonical slot order.
///
/// This is the "what did the profile promise that the rig has not got" signal:
/// a profile device that never connected has no heartbeat and no session
/// history, so nothing else in readiness or equipment health deducts for it. A
/// device in `connecting`, `error`, or `disconnected` — or a slot occupied by a
/// DIFFERENT device than the profile assigned — all count as offline here,
/// matching the fail-closed rule the rest of readiness uses.
///
/// Empty when there is no active profile: absence of a profile is a separate
/// readiness item, not a device fault.
final offlineProfileDeviceNamesProvider = Provider<List<String>>((ref) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return const <String>[];
  final status = ref.watch(profileConnectionStatusProvider(profile));
  return <String>[
    for (final connection in status.connections)
      if (connection.isAssigned &&
          connection.profileState != DeviceConnectionState.connected)
        connection.slot.displayName,
  ];
});
