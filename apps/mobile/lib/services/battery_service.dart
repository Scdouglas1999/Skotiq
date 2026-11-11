// Battery-aware mobile throttling.
//
// PowerService already exists for low-battery *warning* surfaces (notification
// pop, wake-lock release at critical thresholds). BatteryService is the
// *throttling* peer: it exposes a Riverpod-friendly stream of {level,
// isCharging, isLowPower} samples that polling providers consume to decide
// how often to hit the network.
//
// Two services rather than one because:
//   * PowerService is a behaviour engine (acquires wake locks, posts
//     notifications, gates imaging). Mixing display state into it would
//     couple every consumer that just wants the percentage to the full
//     wake-lock + notification pipeline.
//   * BatteryService is purely a *projection* of the battery_plus stream
//     into a typed snapshot. It is allowed to be a singleton because the
//     OS only has one battery; we initialize once at app start and let
//     every consumer subscribe to the broadcast stream.
//
// The stream is event-driven: battery_plus emits a [BatteryState] change
// whenever the OS reports plug/unplug, and we additionally tick every 30 s
// to recompute the percentage (battery_plus doesn't push level changes on
// every percent). The 30 s cadence matches PowerService's own check
// interval so both services see the same level reading; we don't share
// the underlying [Battery] instance because that's a cheap object and
// sharing would mean PowerService.dispose() could kill our subscriptions.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PhoneBatteryState {
  /// Battery percentage, 0–100. -1 when the platform reports unknown.
  final int level;

  /// True when the OS is currently feeding the battery (charging or full).
  final bool isCharging;

  /// True when [level] is below the low-power threshold (20%) AND the
  /// device is not charging. Consumers use this to throttle polling
  /// rates without re-implementing the threshold check.
  final bool isLowPower;

  const PhoneBatteryState({
    required this.level,
    required this.isCharging,
    required this.isLowPower,
  });

  /// Snapshot the OS can't yet describe. Treated as full-power so the
  /// app doesn't spuriously throttle before the first sample lands.
  static const PhoneBatteryState unknown = PhoneBatteryState(
    level: -1,
    isCharging: false,
    isLowPower: false,
  );

  @override
  String toString() =>
      'PhoneBatteryState(level: $level, isCharging: $isCharging, '
      'isLowPower: $isLowPower)';

  @override
  bool operator ==(Object other) {
    return other is PhoneBatteryState &&
        other.level == level &&
        other.isCharging == isCharging &&
        other.isLowPower == isLowPower;
  }

  @override
  int get hashCode => Object.hash(level, isCharging, isLowPower);
}

/// Streams [PhoneBatteryState] snapshots from the OS.
///
/// Usage:
///
///   final state = ref.watch(batteryStateProvider).valueOrNull;
///   if (state?.isLowPower ?? false) { /* throttle */ }
///
/// The service is a singleton because the OS exposes one battery; multiple
/// instances would just duplicate work without changing behaviour.
class BatteryService {
  BatteryService._internal();
  static final BatteryService _instance = BatteryService._internal();
  factory BatteryService() => _instance;

  /// Percentage threshold below which the device is considered "low power".
  /// Matches PowerService's notification trigger so the two services agree
  /// on what "low" means.
  static const int lowPowerThreshold = 20;

  /// How often we recompute the percentage. battery_plus only pushes
  /// charging-state changes, not per-percent updates, so we tick on a timer
  /// to catch the trickle drain. 30 s matches PowerService.
  static const Duration pollInterval = Duration(seconds: 30);

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _stateSubscription;
  Timer? _levelTimer;
  final StreamController<PhoneBatteryState> _controller =
      StreamController<PhoneBatteryState>.broadcast();

  PhoneBatteryState _last = PhoneBatteryState.unknown;
  bool _started = false;

  /// Latest snapshot. [PhoneBatteryState.unknown] until [start] completes.
  PhoneBatteryState get current => _last;

  /// Broadcast stream of state changes. Coalesces no-op samples so
  /// consumers only see real transitions.
  Stream<PhoneBatteryState> get stream => _controller.stream;

  /// Begin sampling. Idempotent — subsequent calls are no-ops.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      // Seed with an immediate sample so consumers don't have to wait for
      // the first 30 s tick to learn the level.
      await _sample();
    } catch (e, st) {
      developer.log(
        'BatteryService initial sample failed: $e',
        name: 'BatteryService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }

    _stateSubscription = _battery.onBatteryStateChanged.listen(
      (_) {
        // The charging-state stream tells us plug/unplug happened; resample
        // immediately so isCharging/isLowPower flip without waiting 30 s.
        unawaited(_sample());
      },
      onError: (Object e, StackTrace st) {
        developer.log(
          'battery_plus state stream errored: $e',
          name: 'BatteryService',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      },
    );

    _levelTimer = Timer.periodic(pollInterval, (_) => unawaited(_sample()));
  }

  Future<void> _sample() async {
    final level = await _battery.batteryLevel;
    final state = await _battery.batteryState;
    final isCharging =
        state == BatteryState.charging || state == BatteryState.full;
    final isLowPower = !isCharging && level >= 0 && level < lowPowerThreshold;
    final next = PhoneBatteryState(
      level: level,
      isCharging: isCharging,
      isLowPower: isLowPower,
    );
    if (next == _last) return;
    _last = next;
    _controller.add(next);
  }

  /// Stop sampling. Tests and the app-tear-down hook call this.
  Future<void> dispose() async {
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    _levelTimer?.cancel();
    _levelTimer = null;
    await _controller.close();
    _started = false;
  }
}

/// Riverpod stream provider for [PhoneBatteryState].
///
/// Eager-seeded with [BatteryService.current] so the first `valueOrNull`
/// read inside a widget doesn't return null on a frame where the OS has
/// already given us a real sample. Stream subscription cleans up via the
/// `ref.onDispose`.
final batteryStateProvider = StreamProvider<PhoneBatteryState>((ref) {
  final service = BatteryService();
  final controller = StreamController<PhoneBatteryState>();
  // Emit the cached snapshot synchronously so widgets reading
  // `.valueOrNull` on first build see a non-null state if the service has
  // already sampled (cold start vs. hot reload distinction).
  if (service.current.level >= 0) {
    controller.add(service.current);
  }
  final sub = service.stream.listen(
    controller.add,
    onError: controller.addError,
  );
  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Convenience boolean for "throttle aggressively". Composes battery
/// state with the optional cellular flag so polling providers can do:
///
///     final slow = ref.watch(shouldThrottleMobileProvider(onCellular: x));
///
/// We expose the override as a parameter rather than wiring connectivity
/// here so the provider stays single-purpose and battery-only — easier to
/// stub in widget tests.
bool shouldThrottlePolling({
  required PhoneBatteryState battery,
  required bool onCellular,
}) {
  if (battery.isLowPower) return true;
  if (onCellular) return true;
  return false;
}

/// Multiplier applied to base polling intervals when
/// [shouldThrottlePolling] is true. Exposed for the unit test to assert
/// against the same constant the producer uses.
const int throttledPollMultiplier = 3;
