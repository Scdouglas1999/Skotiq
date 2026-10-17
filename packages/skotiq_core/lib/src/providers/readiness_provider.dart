import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/equipment/equipment_models.dart';
import '../models/readiness/readiness_models.dart';
import 'dark_library_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/focuser_state_provider.dart';
import 'equipment/mount_state_provider.dart';
import 'equipment/profile_connection_status_provider.dart';
import 'plate_solver_provider.dart';
import 'profiles_provider.dart';
import 'settings_provider.dart';

/// Composes the app's existing setup signals into a single, fail-closed
/// [ReadinessReport].
///
/// Collects booleans from the device-state / settings / plate-solver /
/// dark-library providers and hands them to the pure [buildReadinessReport]
/// (see `models/readiness/readiness_models.dart`), where all readiness *rules*
/// live; this file only wires inputs.
///
/// Absence of positive evidence is "not satisfied": async inputs are read via
/// `.valueOrNull` so a still-loading or errored provider collapses its flag to
/// `false`, and only an explicit [DeviceConnectionState.connected] counts as
/// connected. A disconnected camera or an unreadable settings store must
/// surface as a blocking item rather than degrade to "ready".
final readinessReportProvider = Provider<ReadinessReport>((ref) {
  // Critical devices
  // A profile is "present" if any equipment profile exists. The active-profile
  // selector is derived from the same state, so watching the list is the
  // single, cheapest signal that the user has completed equipment setup.
  final hasProfile = ref.watch(equipmentProfileListProvider).isNotEmpty;

  // Connection is satisfied ONLY on an explicit `connected` state. Every other
  // state (disconnected / connecting / error) is fail-closed to false.
  final cameraConnected =
      ref.watch(cameraStateProvider).connectionState ==
      DeviceConnectionState.connected;
  final mountConnected =
      ref.watch(mountStateProvider).connectionState ==
      DeviceConnectionState.connected;

  // Location & output path (persisted settings)
  // `appSettingsProvider` is async; while it loads (`valueOrNull == null`) or
  // on error, both derived flags fail closed to false.
  final settings = ref.watch(appSettingsProvider).valueOrNull;

  // Only the (0,0) sentinel means unset. Equator and prime-meridian sites are
  // valid observatory locations and must not fail readiness independently.
  final locationSet = settings?.isLocationSet ?? false;

  // The capture output directory is persisted via
  // `SettingsDao.setDefaultImageDirectory`, surfaced here as
  // `imageOutputPath`. Onboarding's `complete()` writes the same field.
  final outputPathSet =
      settings != null && settings.imageOutputPath.trim().isNotEmpty;

  // Plate solver
  // Readiness must reflect the selected solver, not merely some other solver
  // installed on disk. For Auto, either usable engine is sufficient.
  final solverDetection = ref.watch(plateSolverDetectionProvider).valueOrNull;
  final solverPreference = ref.watch(plateSolverPreferenceProvider).valueOrNull;
  final plateSolverReady =
      solverDetection != null &&
      solverPreference != null &&
      solverDetection.supports(solverPreference.choice);

  // Dark library
  // Coverage is satisfied once at least one master dark exists. The stats
  // provider re-runs whenever the library changes; loading/error -> false.
  final stats = ref.watch(darkLibraryStatsProvider).valueOrNull;
  final darkLibraryHasCoverage = stats != null && stats.masterCount > 0;

  // Focus state
  // Focus is "known" only when the focuser is connected AND it reports a
  // current position. A connected focuser that has never reported a position
  // is treated as unknown (caution), never assumed in focus.
  final focuser = ref.watch(focuserStateProvider);
  final focusKnown =
      focuser.connectionState == DeviceConnectionState.connected &&
      focuser.position != null;

  // Other assigned profile devices
  // Camera and mount are already covered by the critical-devices item, so they
  // are filtered out here to avoid double-reporting the same fault.
  final offlineProfileDevices = ref
      .watch(offlineProfileDeviceNamesProvider)
      .where(
        (name) =>
            name != ProfileDeviceSlot.camera.displayName &&
            name != ProfileDeviceSlot.mount.displayName,
      )
      .toList(growable: false);

  // The assignment SET, not just the offline subset: an empty offline list
  // means "nothing assigned is down", which over an empty profile is vacuous.
  // The profile-devices rule needs the counts to tell those apart.
  final assignedProfileSlots = ref.watch(assignedProfileDeviceSlotsProvider);
  final otherAssignedProfileSlots = assignedProfileSlots.where(
    (slot) =>
        slot != ProfileDeviceSlot.camera && slot != ProfileDeviceSlot.mount,
  );

  return buildReadinessReport(
    cameraConnected: cameraConnected,
    mountConnected: mountConnected,
    hasProfile: hasProfile,
    locationSet: locationSet,
    outputPathSet: outputPathSet,
    plateSolverReady: plateSolverReady,
    darkLibraryHasCoverage: darkLibraryHasCoverage,
    focusKnown: focusKnown,
    offlineProfileDevices: offlineProfileDevices,
    hasActiveProfile: ref.watch(activeEquipmentProfileProvider) != null,
    assignedProfileDeviceCount: assignedProfileSlots.length,
    otherAssignedProfileDeviceCount: otherAssignedProfileSlots.length,
  );
});

/// Cheap selector for the top-line readiness level.
///
/// Watch this from chips/pills/badges that only need the traffic-light color
/// and label — it rebuilds only when the *overall* level changes, not on every
/// per-item detail tweak that leaves [ReadinessReport.overall] unchanged.
final readinessOverallProvider = Provider<ReadinessLevel>((ref) {
  return ref.watch(readinessReportProvider).overall;
});
