// The phone's battery as a typed snapshot for the app: the top-bar warning
// and the poll pace read it.
//
// PowerService is the separate behavior engine for low battery (wake locks,
// notifications, gating imaging); this service only projects battery_plus into
// [PhoneBatteryState]. battery_plus pushes plug and unplug but not level
// changes, so the level is also sampled every 30 s, the same cadence as
// PowerService.

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/services.dart';

class PhoneBatteryState {
  /// Battery percentage, 0–100. -1 when the platform reports none.
  final int level;

  /// True when the OS is currently feeding the battery (charging or full).
  final bool isCharging;

  /// True when [level] is below [BatteryService.lowPowerThreshold] and the
  /// phone is not charging.
  final bool isLowPower;

  /// True while the OS battery saver (Android Battery Saver, iOS Low Power
  /// Mode) is on.
  final bool isSaverOn;

  const PhoneBatteryState({
    required this.level,
    required this.isCharging,
    required this.isLowPower,
    this.isSaverOn = false,
  });

  /// No reading yet, or no battery. Treated as full power so nothing slows
  /// down before the first sample lands.
  static const PhoneBatteryState unknown = PhoneBatteryState(
    level: -1,
    isCharging: false,
    isLowPower: false,
  );

  @override
  String toString() =>
      'PhoneBatteryState(level: $level, isCharging: $isCharging, '
      'isLowPower: $isLowPower, isSaverOn: $isSaverOn)';

  @override
  bool operator ==(Object other) {
    return other is PhoneBatteryState &&
        other.level == level &&
        other.isCharging == isCharging &&
        other.isLowPower == isLowPower &&
        other.isSaverOn == isSaverOn;
  }

  @override
  int get hashCode => Object.hash(level, isCharging, isLowPower, isSaverOn);
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
      Log.error(
        'BatteryService initial sample failed: $e',
        source: 'BatteryService',
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
        Log.error(
          'battery_plus state stream errored: $e',
          source: 'BatteryService',
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
    // A machine with no battery (a desktop running the phone build) reports
    // state unknown at 0 %, which would otherwise read as nearly empty.
    final next = state == BatteryState.unknown || level < 0
        ? PhoneBatteryState.unknown
        : _stateFor(level, state, isSaverOn: await _saverOn());
    if (next == _last) return;
    _last = next;
    _controller.add(next);
  }

  static PhoneBatteryState _stateFor(
    int level,
    BatteryState state, {
    required bool isSaverOn,
  }) {
    final isCharging =
        state == BatteryState.charging || state == BatteryState.full;
    return PhoneBatteryState(
      level: level,
      isCharging: isCharging,
      isLowPower: !isCharging && level < lowPowerThreshold,
      isSaverOn: isSaverOn,
    );
  }

  bool _saverUnsupported = false;

  /// Whether battery saver is on, or false where the platform cannot say
  /// (battery_plus has no saver query on Linux).
  Future<bool> _saverOn() async {
    if (_saverUnsupported) return false;
    try {
      return await _battery.isInBatterySaveMode;
    } on UnimplementedError {
      _saverUnsupported = true;
    } on MissingPluginException {
      _saverUnsupported = true;
    }
    Log.debug(
      'Battery saver state is not available on this platform',
      source: 'BatteryService',
    );
    return false;
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
