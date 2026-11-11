// How hard the phone polls the host, from its battery and network.
//
// Every background poll of the host on the phone (host data with no change
// event, session hydration, the live stack preview) waits its base interval
// times the app-wide `PollPace` from skotiq_core. This file sets that pace.
// One simple rule: a third of the polling while the battery is low, battery
// saver is on, or the phone is on cellular data. PowerService already warns
// about a low battery and a critical one, so the rule does not tier.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'battery_service.dart';
import 'network_service.dart';

/// The pace while slowed: each poll waits this many times its base interval.
const int throttledPollPace = 3;

/// The poll pace for the phone's battery and network.
int pollPaceFor({
  required PhoneBatteryState battery,
  required bool onCellular,
}) {
  if (battery.isLowPower || battery.isSaverOn || onCellular) {
    return throttledPollPace;
  }
  return 1;
}

bool _onCellular(NetworkServiceState state) =>
    state.hasMobile && !state.hasWifi;

/// Keeps [PollPace] in step with the phone's battery and network for as long
/// as it is listened to; the phone app runs it always.
final pollPaceProvider = Provider<int>((ref) {
  var battery =
      ref.read(batteryStateProvider).valueOrNull ?? BatteryService().current;
  var onCellular = _onCellular(NetworkService().currentState);

  void apply() {
    final pace = pollPaceFor(battery: battery, onCellular: onCellular);
    if (PollPace.multiplier != pace) PollPace.multiplier = pace;
    ref.state = pace;
  }

  ref.listen<AsyncValue<PhoneBatteryState>>(batteryStateProvider, (_, next) {
    final value = next.valueOrNull;
    if (value == null) return;
    battery = value;
    apply();
  });
  final network = NetworkService().stateStream.listen((state) {
    onCellular = _onCellular(state);
    apply();
  });
  ref.onDispose(() {
    unawaited(network.cancel());
    PollPace.multiplier = 1;
  });

  final pace = pollPaceFor(battery: battery, onCellular: onCellular);
  PollPace.multiplier = pace;
  return pace;
});
