import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';

// Switch device state provider, mirroring the safety-monitor
// shape (Audit C1). The notifier owns the connect-with-retry loop and the
// `autoReconnectEnabled` flag that `DeviceService._getAutoReconnectFor`
// consults when a Disconnected event arrives.
//
// Per-channel state mutation is driven by [DeviceService.setSwitchChannel],
// which calls the Rust bridge (`api_switch_set_state`) and then calls
// [setChannelState] here to reconcile the cached snapshot. The
// [setChannels] helper is used by [DeviceService.refreshSwitchChannels]
// to populate the channel snapshot on connect and on manual refresh.
//
// Note: All async callbacks and stream listeners check `mounted` before
// updating state to prevent updates after disposal.

final switchStateProvider =
    StateNotifierProvider<SwitchStateNotifier, SwitchState>((ref) {
      return SwitchStateNotifier(ref);
    });

class SwitchStateNotifier extends DeviceSlotNotifier<SwitchState> {
  SwitchStateNotifier(Ref ref)
    : super(ref, DeviceType.switch_, const SwitchState());

  /// Update the cached channel snapshot. The Rust bridge does not push
  /// these on a stream yet; DeviceService polls explicitly on connect
  /// and after any `setSwitchChannel` write.
  ///
  /// When [refreshedAt] is provided it is recorded as the last-poll
  /// timestamp the UI uses for the "Refresh" affordance; pass null when
  /// only updating the count without re-polling labels/states.
  void setChannels({
    required int count,
    List<String>? names,
    List<bool>? states,
    List<String>? descriptions,
    List<bool>? isBoolean,
    List<double>? values,
    List<double>? minValues,
    List<double>? maxValues,
    List<double>? steps,
    List<bool>? canWrite,
    DateTime? refreshedAt,
  }) {
    state = state.copyWith(
      channelCount: count,
      channelNames: names ?? state.channelNames,
      channelStates: states ?? state.channelStates,
      channelDescriptions: descriptions ?? state.channelDescriptions,
      channelIsBoolean: isBoolean ?? state.channelIsBoolean,
      channelValues: values ?? state.channelValues,
      channelMinValues: minValues ?? state.channelMinValues,
      channelMaxValues: maxValues ?? state.channelMaxValues,
      channelSteps: steps ?? state.channelSteps,
      channelCanWrite: canWrite ?? state.channelCanWrite,
      lastChannelRefresh: refreshedAt,
    );
  }

  /// Update a single channel's boolean state after a successful bridge
  /// write. The index is bounds-checked against the cached
  /// [SwitchState.channelStates] list; out-of-range indices are
  /// silently ignored because the UI cannot have rendered a row for a
  /// channel that does not exist in the snapshot. This is the only
  /// mutation path the UI is allowed to use — direct optimistic writes
  /// would lie to the user about hardware state.
  void setChannelState(int index, bool on) {
    final current = state.channelStates;
    if (index < 0 || index >= current.length) return;
    final next = List<bool>.from(current);
    next[index] = on;
    final values = List<double>.from(state.channelValues);
    if (index < values.length) {
      final min = index < state.channelMinValues.length
          ? state.channelMinValues[index]
          : 0.0;
      final max = index < state.channelMaxValues.length
          ? state.channelMaxValues[index]
          : 1.0;
      values[index] = on ? max : min;
    }
    state = state.copyWith(channelStates: next, channelValues: values);
  }

  /// Reconcile a numeric/PWM channel after the hardware confirms a write.
  void setChannelValue(int index, double value) {
    final current = state.channelValues;
    if (index < 0 || index >= current.length) return;
    final values = List<double>.from(current);
    values[index] = value;

    final states = List<bool>.from(state.channelStates);
    if (index < states.length) {
      final min = index < state.channelMinValues.length
          ? state.channelMinValues[index]
          : 0.0;
      final max = index < state.channelMaxValues.length
          ? state.channelMaxValues[index]
          : 1.0;
      states[index] = value > min + ((max - min) / 2);
    }
    state = state.copyWith(channelValues: values, channelStates: states);
  }
}
