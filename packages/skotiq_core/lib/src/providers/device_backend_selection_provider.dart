import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/device_service.dart';

/// Provider that tracks user's backend selection per device (by canonical name)
///
/// Key: canonical device name (normalized)
/// Value: selected DriverType
///
/// When a user selects a specific backend for a device, it's stored here.
/// If no selection exists, the device uses its recommended backend.
final deviceBackendSelectionProvider =
    StateNotifierProvider<
      DeviceBackendSelectionNotifier,
      Map<String, DriverType>
    >((ref) {
      return DeviceBackendSelectionNotifier();
    });

class DeviceBackendSelectionNotifier
    extends StateNotifier<Map<String, DriverType>> {
  DeviceBackendSelectionNotifier() : super({});

  /// Select a backend for a device
  void selectBackend(String canonicalName, DriverType backend) {
    state = {...state, canonicalName: backend};
  }

  /// Clear selection for a device (will use recommended backend)
  void clearSelection(String canonicalName) {
    final newState = Map<String, DriverType>.from(state);
    newState.remove(canonicalName);
    state = newState;
  }

  /// Get the selected backend for a device (null if not explicitly selected)
  DriverType? getSelection(String canonicalName) {
    return state[canonicalName];
  }

  /// Clear all selections
  void clearAll() {
    state = {};
  }

  /// Load selections from saved preferences (e.g., from profile)
  void loadSelections(Map<String, DriverType> selections) {
    state = Map<String, DriverType>.from(selections);
  }

  /// Export selections for saving
  Map<String, DriverType> exportSelections() {
    return Map<String, DriverType>.from(state);
  }
}

/// Family provider to get the selected backend for a specific device
///
/// Usage: ref.watch(selectedBackendForDeviceProvider('asi294mc pro'))
final selectedBackendForDeviceProvider = Provider.family<DriverType?, String>((
  ref,
  canonicalName,
) {
  final selections = ref.watch(deviceBackendSelectionProvider);
  return selections[canonicalName];
});
