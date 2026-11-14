import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../profiles_provider.dart';
import '../../models/equipment_profile_model.dart';
import '../device_service_providers.dart';
import '../../services/logging_service.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

final filterWheelStateProvider =
    StateNotifierProvider<FilterWheelStateNotifier, FilterWheelState>((ref) {
      return FilterWheelStateNotifier(ref);
    });

class FilterWheelStateNotifier extends DeviceSlotNotifier<FilterWheelState> {
  FilterWheelStateNotifier(Ref ref)
    : super(ref, DeviceType.filterWheel, const FilterWheelState()) {
    // Watch for profile changes and re-sync filter names when the active
    // profile's filter names are updated (e.g. user edits profile and saves).
    ref.listen<EquipmentProfileModel?>(activeEquipmentProfileProvider, (
      previous,
      next,
    ) {
      if (!mounted) return;
      if (state.connectionState != DeviceConnectionState.connected) return;
      if (state.deviceId == null) return;

      final previousNames = previous?.filterNames ?? [];
      final nextNames = next?.filterNames ?? [];
      if (_filterNamesEqual(previousNames, nextNames)) return;

      Log.info(
        'FilterWheelStateNotifier: Active profile filter names changed, re-syncing',
        source: 'FilterWheelStateNotifier',
      );
      _syncProfileFilterNamesToDriver(state.deviceId!);
    });
  }

  static bool _filterNamesEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Re-sync filter names to the native driver when the active profile changes
  /// while the filter wheel is already connected.
  ///
  /// Called by the ref.listen callback in the constructor when profile filter
  /// names are updated (e.g., user edits profile and saves).
  ///
  /// Initial sync on connection is handled by DeviceService.connect.
  Future<void> _syncProfileFilterNamesToDriver(String deviceId) async {
    try {
      // Priority 1: Check active profile filter names
      final activeProfile = ref.read(activeEquipmentProfileProvider);
      if (activeProfile != null && activeProfile.filterNames.isNotEmpty) {
        final profileFilterNames = activeProfile.filterNames;
        final driverNames = state.filterNames;
        Log.info(
          'FilterWheelStateNotifier: Profile has ${profileFilterNames.length} names, driver has ${driverNames.length} slots',
          source: 'FilterWheelStateNotifier',
        );

        // Pad profile names to match the wheel's actual slot count so no slots are lost
        final List<String> syncedNames;
        if (profileFilterNames.length < driverNames.length) {
          syncedNames = [
            ...profileFilterNames,
            ...driverNames.sublist(profileFilterNames.length),
          ];
          Log.info(
            'FilterWheelStateNotifier: Padded profile names to ${syncedNames.length}: $syncedNames',
            source: 'FilterWheelStateNotifier',
          );
        } else {
          syncedNames = profileFilterNames.length > driverNames.length
              ? profileFilterNames.sublist(0, driverNames.length)
              : profileFilterNames;
        }

        await ref.read(deviceServiceProvider).setFilterWheelNames(syncedNames);
        Log.info(
          'FilterWheelStateNotifier: Profile filter names synced successfully',
          source: 'FilterWheelStateNotifier',
        );
        return;
      }

      // Priority 2: Check session filter names
      final sessionFilterNames = ref.read(sessionFilterNamesProvider);
      if (sessionFilterNames != null && sessionFilterNames.isNotEmpty) {
        final driverNames = state.filterNames;
        Log.info(
          'FilterWheelStateNotifier: Session has ${sessionFilterNames.length} names, driver has ${driverNames.length} slots',
          source: 'FilterWheelStateNotifier',
        );

        // Pad session names to match the wheel's actual slot count
        final List<String> syncedNames;
        if (sessionFilterNames.length < driverNames.length) {
          syncedNames = [
            ...sessionFilterNames,
            ...driverNames.sublist(sessionFilterNames.length),
          ];
        } else {
          syncedNames = sessionFilterNames.length > driverNames.length
              ? sessionFilterNames.sublist(0, driverNames.length)
              : sessionFilterNames;
        }

        await ref.read(deviceServiceProvider).setFilterWheelNames(syncedNames);
        Log.info(
          'FilterWheelStateNotifier: Session filter names synced successfully',
          source: 'FilterWheelStateNotifier',
        );
        return;
      }

      // Priority 3: Use driver-reported names (no sync needed, they're already there)
      Log.info(
        'FilterWheelStateNotifier: No profile or session filter names - using driver-reported names',
        source: 'FilterWheelStateNotifier',
      );
    } catch (e) {
      // Don't fail connection if filter name sync fails - log and continue
      Log.error(
        'FilterWheelStateNotifier: Failed to sync filter names: $e',
        source: 'FilterWheelStateNotifier',
        error: e,
      );
    }
  }

  @override
  void setConnected({List<String>? filterNames}) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.connected,
      filterNames: filterNames,
      clearError: true,
    );
  }

  void setDeviceName(String deviceName) {
    state = state.copyWith(deviceName: deviceName);
  }

  void updatePosition(int position) {
    state = state.copyWith(currentPosition: position);
  }

  /// The slot names the wheel now holds, from the host's `FilterNames`
  /// property event.
  void setFilterNames(List<String> names) {
    state = state.copyWith(filterNames: names);
  }

  void setMoving(bool moving) {
    state = state.copyWith(isMoving: moving);
  }

  /// Set session-level filter names (without requiring an equipment profile).
  ///
  /// This allows users to name their filters for the current session without
  /// creating or modifying an equipment profile. The names are stored in
  /// [sessionFilterNamesProvider] and will be used when:
  /// - No equipment profile is active, OR
  /// - The active equipment profile has no filter names configured
  ///
  /// If [syncToDriver] is true and a filter wheel is connected, the names
  /// will be immediately synced to the native driver.
  Future<void> setSessionFilterNames(
    List<String> names, {
    bool syncToDriver = true,
  }) async {
    ref.read(sessionFilterNamesProvider.notifier).state = names;

    if (syncToDriver &&
        state.connectionState == DeviceConnectionState.connected &&
        state.deviceId != null) {
      try {
        Log.info(
          'FilterWheelStateNotifier: Syncing session filter names to driver: $names',
          source: 'FilterWheelStateNotifier',
        );
        await ref.read(deviceServiceProvider).setFilterWheelNames(names);
        Log.info(
          'FilterWheelStateNotifier: Session filter names synced to driver',
          source: 'FilterWheelStateNotifier',
        );
      } catch (e) {
        Log.error(
          'FilterWheelStateNotifier: Failed to sync session filter names to driver: $e',
          source: 'FilterWheelStateNotifier',
          error: e,
        );
        // Don't throw - the names are still stored locally
      }
    } else {
      // No live driver owns this list yet; keep the session-only names visible
      // until the next connection syncs them to real wheel slots.
      state = state.copyWith(filterNames: names);
    }
  }

  /// Clear session-level filter names.
  ///
  /// This will cause the filter wheel to fall back to profile names (if available)
  /// or driver-reported names on the next connection.
  void clearSessionFilterNames() {
    ref.read(sessionFilterNamesProvider.notifier).state = null;
  }
}

/// Matches generic ASCOM/INDI slot labels such as "Filter 1" or "filter2".
final genericFilterSlotNamePattern = RegExp(
  r'^filter\s*\d+$',
  caseSensitive: false,
);

/// Returns true when [name] is a driver-default slot label with no band info.
bool isGenericFilterSlotName(String name) =>
    genericFilterSlotNamePattern.hasMatch(name.trim());

/// Prefer profile filter names when the wheel reports only generic slot labels.
///
/// When every [wheelNames] entry is generic and [profileNames] contains at
/// least one real band name, profile names are used (padded or trimmed to the
/// wheel slot count). When both sides are generic, [wheelNames] is kept.
List<String> resolveEffectiveFilterNames({
  required List<String> wheelNames,
  required List<String> profileNames,
}) {
  if (wheelNames.isEmpty) return profileNames;

  final wheelAllGeneric = wheelNames.every(isGenericFilterSlotName);
  final profileHasRealNames =
      profileNames.isNotEmpty &&
      profileNames.any((name) => !isGenericFilterSlotName(name));

  if (wheelAllGeneric && profileHasRealNames) {
    if (profileNames.length >= wheelNames.length) {
      return profileNames.sublist(0, wheelNames.length);
    }
    return [...profileNames, ...wheelNames.sublist(profileNames.length)];
  }

  return wheelNames;
}

/// The filters a plan can use, in slot order: the one list every filter
/// picker, check and plan builder reads.
///
/// A connected wheel that reports its slots decides the list, because those
/// are the filters a run can reach (connecting writes the profile's names into
/// a wheel that holds names). A wheel that labels its slots only "Filter 1",
/// "Filter 2"... takes the profile's names slot by slot. With no wheel
/// connected the active profile's filters are the list.
final effectiveFiltersProvider = Provider<List<String>>((ref) {
  final wheel = ref.watch(filterWheelStateProvider);
  final profileFilters = ref.watch(profileFiltersProvider);
  if (wheel.connectionState == DeviceConnectionState.connected &&
      wheel.filterNames.isNotEmpty) {
    return resolveEffectiveFilterNames(
      wheelNames: wheel.filterNames,
      profileNames: profileFilters,
    );
  }
  return profileFilters;
});

/// What a filter picker says when [effectiveFiltersProvider] is empty.
const String noFiltersToPickHint =
    'No filters — connect a filter wheel or add them to the profile';

/// Session-only filter names (no profile required).
///
/// When a filter wheel connects, filter names resolve in this priority order:
/// 1. Active profile filter names (if the profile has them configured)
/// 2. Session filter names (set via this provider)
/// 3. Driver-reported names (from the backend/hardware)
final sessionFilterNamesProvider = StateProvider<List<String>?>((ref) => null);
