import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import '../profiles_provider.dart';
import 'equipment_retry_defaults.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Filter wheel state provider
final filterWheelStateProvider =
    StateNotifierProvider<FilterWheelStateNotifier, FilterWheelState>((ref) {
      return FilterWheelStateNotifier(ref);
    });

class FilterWheelStateNotifier extends StateNotifier<FilterWheelState>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  FilterWheelStateNotifier(this._ref) : super(const FilterWheelState()) {
    // Watch for profile changes and re-sync filter names when the active
    // profile's filter names are updated (e.g. user edits profile and saves).
    _ref.listen<EquipmentProfileModel?>(activeEquipmentProfileProvider, (
      previous,
      next,
    ) {
      if (!mounted) return;
      if (state.connectionState != DeviceConnectionState.connected) return;
      if (state.deviceId == null) return;

      // Only re-sync if filter names actually changed
      final previousNames = previous?.filterNames ?? [];
      final nextNames = next?.filterNames ?? [];
      if (_filterNamesEqual(previousNames, nextNames)) return;

      developer.log(
        'FilterWheelStateNotifier: Active profile filter names changed, re-syncing',
        name: 'FilterWheelStateNotifier',
        level: 800,
      );
      _syncProfileFilterNamesToDriver(state.deviceId!);
    });
  }

  /// Compare two filter name lists for equality
  static bool _filterNamesEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> connect(
    String deviceId, {
    int maxRetries = kDefaultMaxRetries,
  }) async {
    final revision = ++_connectionRevision;
    _retryAttempts = 0;
    _setConnectingState(deviceId, deviceId);
    await _connectWithRetry(deviceId, maxRetries, revision);
  }

  Future<void> _connectWithRetry(
    String deviceId,
    int maxRetries,
    int revision,
  ) async {
    try {
      final deviceService = _ref.read(deviceServiceProvider);
      // DeviceService.connectFilterWheel handles:
      // 1. Connecting to the hardware
      // 2. Populating filter names from the driver
      // 3. Syncing profile/session filter names to the driver
      await deviceService.connectFilterWheel(deviceId);
      if (!_isCurrentConnection(deviceId, revision)) return;
      _retryAttempts = 0;
    } catch (e) {
      if (!_isCurrentAttempt(deviceId, revision)) return;
      _retryAttempts++;
      final error = DeviceError.fromException(
        e,
        deviceId: deviceId,
        retryAttempts: _retryAttempts,
      );

      if (error.recoverable && _retryAttempts < maxRetries) {
        state = state.copyWith(lastError: error);
        await Future.delayed(kDefaultRetryDelay * _retryAttempts);
        if (!_isCurrentAttempt(deviceId, revision)) return;
        _setConnectingState(deviceId, deviceId);
        await _connectWithRetry(deviceId, maxRetries, revision);
      } else {
        state = state.copyWith(
          connectionState: DeviceConnectionState.error,
          lastError: error,
        );
      }
    }
  }

  /// Re-sync filter names to the native driver when the active profile changes
  /// while the filter wheel is already connected.
  ///
  /// Called by the _ref.listen callback in the constructor when profile filter
  /// names are updated (e.g., user edits profile and saves).
  ///
  /// Initial sync on connection is handled by DeviceService.connectFilterWheel.
  Future<void> _syncProfileFilterNamesToDriver(String deviceId) async {
    try {
      // Priority 1: Check active profile filter names
      final activeProfile = _ref.read(activeEquipmentProfileProvider);
      if (activeProfile != null && activeProfile.filterNames.isNotEmpty) {
        final profileFilterNames = activeProfile.filterNames;
        final driverNames = state.filterNames;
        developer.log(
          'FilterWheelStateNotifier: Profile has ${profileFilterNames.length} names, driver has ${driverNames.length} slots',
          name: 'FilterWheelStateNotifier',
          level: 800,
        );

        // Pad profile names to match the wheel's actual slot count so no slots are lost
        final List<String> syncedNames;
        if (profileFilterNames.length < driverNames.length) {
          syncedNames = [
            ...profileFilterNames,
            ...driverNames.sublist(profileFilterNames.length),
          ];
          developer.log(
            'FilterWheelStateNotifier: Padded profile names to ${syncedNames.length}: $syncedNames',
            name: 'FilterWheelStateNotifier',
            level: 800,
          );
        } else {
          syncedNames = profileFilterNames.length > driverNames.length
              ? profileFilterNames.sublist(0, driverNames.length)
              : profileFilterNames;
        }

        await _ref.read(deviceServiceProvider).setFilterWheelNames(syncedNames);
        developer.log(
          'FilterWheelStateNotifier: Profile filter names synced successfully',
          name: 'FilterWheelStateNotifier',
          level: 800,
        );
        return;
      }

      // Priority 2: Check session filter names
      final sessionFilterNames = _ref.read(sessionFilterNamesProvider);
      if (sessionFilterNames != null && sessionFilterNames.isNotEmpty) {
        final driverNames = state.filterNames;
        developer.log(
          'FilterWheelStateNotifier: Session has ${sessionFilterNames.length} names, driver has ${driverNames.length} slots',
          name: 'FilterWheelStateNotifier',
          level: 800,
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

        await _ref.read(deviceServiceProvider).setFilterWheelNames(syncedNames);
        developer.log(
          'FilterWheelStateNotifier: Session filter names synced successfully',
          name: 'FilterWheelStateNotifier',
          level: 800,
        );
        return;
      }

      // Priority 3: Use driver-reported names (no sync needed, they're already there)
      developer.log(
        'FilterWheelStateNotifier: No profile or session filter names - using driver-reported names',
        name: 'FilterWheelStateNotifier',
        level: 800,
      );
    } catch (e) {
      // Don't fail connection if filter name sync fails - log and continue
      developer.log(
        'FilterWheelStateNotifier: Failed to sync filter names: $e',
        name: 'FilterWheelStateNotifier',
        level: 1000,
        error: e,
      );
    }
  }

  Future<void> retryConnection() async {
    if (state.deviceId != null) {
      await connect(state.deviceId!);
    }
  }

  void clearError() {
    state = state.clearError();
  }

  Future<void> disconnect() async {
    if (state.deviceId == null) return;
    final revision = ++_connectionRevision;
    final deviceService = _ref.read(deviceServiceProvider);
    await deviceService.disconnectFilterWheel();
    if (mounted && revision == _connectionRevision) setDisconnected();
  }

  @override
  void setConnecting(String deviceId, [String? deviceName]) {
    _setConnectingState(deviceId, deviceName);
  }

  void _setConnectingState(String deviceId, [String? deviceName]) {
    // Preserve `lastError` across Connecting; see camera
    // provider for the full rationale.
    state = state.copyWith(
      connectionState: DeviceConnectionState.connecting,
      deviceId: deviceId,
      deviceName: deviceName ?? state.deviceName ?? deviceId,
    );
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

  @override
  void setDisconnected() {
    final preservedAutoReconnect = state.autoReconnectEnabled;
    state = FilterWheelState(autoReconnectEnabled: preservedAutoReconnect);
  }

  bool _isCurrentConnection(String deviceId, int revision) =>
      mounted && revision == _connectionRevision && state.deviceId == deviceId;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      mounted &&
      revision == _connectionRevision &&
      (state.deviceId == null || state.deviceId == deviceId);

  /// Enable or disable auto-reconnection for the filter wheel.
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  void updatePosition(int position) {
    state = state.copyWith(currentPosition: position);
  }

  void setMoving(bool moving) {
    state = state.copyWith(isMoving: moving);
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
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
    // Store in the session provider
    _ref.read(sessionFilterNamesProvider.notifier).state = names;

    // Optionally sync to driver if connected
    if (syncToDriver &&
        state.connectionState == DeviceConnectionState.connected &&
        state.deviceId != null) {
      try {
        developer.log(
          'FilterWheelStateNotifier: Syncing session filter names to driver: $names',
          name: 'FilterWheelStateNotifier',
          level: 800,
        );
        await _ref.read(deviceServiceProvider).setFilterWheelNames(names);
        developer.log(
          'FilterWheelStateNotifier: Session filter names synced to driver',
          name: 'FilterWheelStateNotifier',
          level: 800,
        );
      } catch (e) {
        developer.log(
          'FilterWheelStateNotifier: Failed to sync session filter names to driver: $e',
          name: 'FilterWheelStateNotifier',
          level: 1000,
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
    _ref.read(sessionFilterNamesProvider.notifier).state = null;
  }
}

// Effective filters provider

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

/// Connected filter wheel names when online; otherwise profile filter names.
/// Generic wheel slot labels fall back to profile names when available.
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

// Session filter names provider

/// Session-only filter names (no profile required).
///
/// When a filter wheel connects, filter names resolve in this priority order:
/// 1. Active profile filter names (if the profile has them configured)
/// 2. Session filter names (set via this provider)
/// 3. Driver-reported names (from the backend/hardware)
final sessionFilterNamesProvider = StateProvider<List<String>?>((ref) => null);
