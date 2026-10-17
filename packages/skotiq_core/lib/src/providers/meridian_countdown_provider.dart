import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/equipment/equipment_models.dart'
    show DeviceConnectionState, MountState;
import '../models/meridian_flip_settings.dart';
import '../models/sequence/sequence_models.dart' show SequenceExecutionState;
import 'equipment_provider.dart' show mountStateProvider;
import 'meridian_flip_provider.dart'
    show
        computeHourAngleHours,
        computeLocalSiderealTimeHours,
        effectiveMeridianFlipSettingsProvider,
        isMeridianFlipEnabledProvider;
import 'sequence_provider.dart' show sequenceExecutionStateProvider;
import 'settings_provider.dart' show appSettingsProvider;

/// Derived, banner-facing model of "how long until the next meridian flip".
///
/// Why this is a *separate* provider from the [MeridianFlipStandaloneMonitor]:
///   The monitor is a side-effecting watchdog — it fires notifications and
///   mutates flip-execution state. The countdown is a pure, read-only
///   projection consumed by the live-capture banner. Keeping them apart means
///   mounting the banner never perturbs the monitor's cooldown bookkeeping, and
///   the banner can recompute on its own 15-second cadence regardless of
///   whether standalone monitoring is even enabled.
///
/// When the countdown is *not* armed, [disabledReason] always carries an
/// operator-facing explanation. The banner never implies the user must act
/// manually: the flip is handled either by the Rust `meridian_flip` trigger
/// (always-on watchdog) or, during a sequence, by the in-sequence flip node.
class MeridianCountdownState extends Equatable {
  /// Whether a meaningful countdown is currently being tracked.
  ///
  /// Armed requires: a connected, tracking, un-parked mount with a known RA, a
  /// real observer location (not the 0,0 default), and meridian-flip enabled in
  /// settings. When false, [disabledReason] explains why.
  final bool isArmed;

  /// Time remaining until the configured flip threshold is reached.
  ///
  /// `null` when not computable — either the mount/location preconditions are
  /// unmet, or the active trigger method ([MeridianTriggerMethod.minutesBeforeLimit]
  /// / [MeridianTriggerMethod.onTrackingLimitHit]) depends on mount-advertised
  /// tracking-limit state that only the Rust trigger evaluator carries.
  final Duration? timeToFlip;

  /// Always `true`: the meridian flip is performed by an automatic watchdog
  /// (the Rust `meridian_flip` trigger) or the in-sequence flip node. The banner
  /// must use this to phrase the message as "handled automatically", never as a
  /// prompt for manual intervention.
  final bool isAutomaticWatchdog;

  /// `true` when a sequence is running or paused, meaning the in-sequence flip
  /// node / Rust trigger owns the flip. The banner should phrase the countdown
  /// as "handled automatically by the sequence" in this case. Also set true for
  /// the tracking-limit methods, whose decision lives entirely in Rust.
  final bool isSequencerOwned;

  /// Operator-facing reason the countdown is not armed (or is owned elsewhere).
  ///
  /// Non-null whenever [isArmed] is false, and also non-null for the
  /// sequencer-owned tracking-limit methods even though a sequence may not be
  /// running. `null` only when a live numeric countdown is being shown.
  final String? disabledReason;

  /// The configured trigger method, echoed so the banner can label the method.
  final MeridianTriggerMethod method;

  /// Current mount hour angle in hours, normalized to (-12, +12]. Positive means
  /// the target is west of the meridian (already crossed). Zero when unknown.
  final double hourAngleHours;

  /// Mount-reported side of pier, when the driver advertises it. Lets the banner
  /// hint at flip direction. `null` when unknown.
  final String? sideOfPier;

  const MeridianCountdownState({
    required this.isArmed,
    required this.timeToFlip,
    required this.isAutomaticWatchdog,
    required this.isSequencerOwned,
    required this.disabledReason,
    required this.method,
    required this.hourAngleHours,
    required this.sideOfPier,
  });

  /// Whether the mount is already past the configured threshold and a flip is
  /// imminent (countdown has reached or passed zero).
  bool get isFlipImminent => isArmed && timeToFlip == Duration.zero;

  @override
  List<Object?> get props => [
    isArmed,
    timeToFlip,
    isAutomaticWatchdog,
    isSequencerOwned,
    disabledReason,
    method,
    hourAngleHours,
    sideOfPier,
  ];
}

/// Refresh cadence for the countdown stream.
///
/// Why 15s: the mount's hour angle advances at the sidereal rate (15"/sec), so
/// sub-minute resolution buys nothing visually, while a 15-second tick keeps the
/// banner's "minutes remaining" readout fresh without burning a finer timer.
const Duration kMeridianCountdownTick = Duration(seconds: 15);

/// Pure, fully testable computation behind [meridianCountdownProvider].
///
/// Mirrors [MeridianFlipStandaloneMonitor.evaluateOnce]'s HA math and arming
/// preconditions exactly, but produces a read-only projection instead of firing
/// side effects. Tested directly in `meridian_countdown_provider_test.dart`
/// with no timers.
///
/// [nowUtc] is injectable for deterministic tests; production passes the live
/// `DateTime.now().toUtc()`.
MeridianCountdownState computeMeridianCountdown({
  required MountState mount,
  required double? longitude,
  required double? latitude,
  required MeridianFlipSettings settings,
  required SequenceExecutionState execState,
  required bool enabled,
  DateTime? nowUtc,
}) {
  final sequencerActive =
      execState == SequenceExecutionState.running ||
      execState == SequenceExecutionState.paused;
  final method = settings.triggerMethod;
  final sideOfPier = mount.sideOfPier;

  MeridianCountdownState notArmed(
    String reason, {
    bool ownedBySequencer = false,
  }) {
    return MeridianCountdownState(
      isArmed: false,
      timeToFlip: null,
      isAutomaticWatchdog: true,
      isSequencerOwned: ownedBySequencer || sequencerActive,
      disabledReason: reason,
      method: method,
      hourAngleHours: 0.0,
      sideOfPier: sideOfPier,
    );
  }

  // Arming preconditions (mirror MeridianFlipStandaloneMonitor)
  if (!enabled) {
    return notArmed('Auto meridian flip is turned off');
  }
  if (mount.connectionState != DeviceConnectionState.connected) {
    return notArmed('Mount not connected');
  }
  if (mount.isParked) {
    return notArmed('Mount is parked');
  }
  if (!mount.isTracking) {
    return notArmed('Mount not tracking');
  }
  if (mount.ra == null) {
    return notArmed('Mount has not reported its position yet');
  }
  // Why: HA computation needs a real longitude. Refuse to compute from a 0,0
  // default — that would be a spurious countdown.
  final lon = longitude;
  final lat = latitude;
  if (lon == null || lat == null || (lon == 0.0 && lat == 0.0)) {
    return notArmed('Set your location in Settings');
  }

  // Tracking-limit methods are Rust-owned — explicitly skip the Dart math
  // The minutes-before-limit and on-tracking-limit-hit decisions depend on
  // mount-advertised tracking-limit state that only the Rust trigger evaluator
  // (triggers.rs) carries. Compute HA for display but emit no numeric countdown.
  final lst = computeLocalSiderealTimeHours(
    (nowUtc ?? DateTime.now().toUtc()),
    lon,
  );
  final ha = computeHourAngleHours(mount.ra!, lst);

  if (method == MeridianTriggerMethod.minutesBeforeLimit ||
      method == MeridianTriggerMethod.onTrackingLimitHit) {
    return MeridianCountdownState(
      isArmed: true,
      timeToFlip: null,
      isAutomaticWatchdog: true,
      isSequencerOwned: true,
      disabledReason: 'Monitored by sequencer (tracking-limit method)',
      method: method,
      hourAngleHours: ha,
      sideOfPier: sideOfPier,
    );
  }

  // Hour-angle-based methods — a real numeric countdown
  // Threshold expressed in hours of HA at which the flip should occur:
  //   minutesPastMeridian:  threshold = minutesPastMeridian / 60
  //   hourAngleThreshold:   threshold = hourAngleThreshold (already in hours)
  // Minutes until the threshold is reached = (thresholdHours - HA) * 60.
  final double thresholdHours;
  switch (method) {
    case MeridianTriggerMethod.minutesPastMeridian:
      thresholdHours = settings.minutesPastMeridian / 60.0;
      break;
    case MeridianTriggerMethod.hourAngleThreshold:
      thresholdHours = settings.hourAngleThreshold;
      break;
    case MeridianTriggerMethod.minutesBeforeLimit:
    case MeridianTriggerMethod.onTrackingLimitHit:
      // Unreachable: handled above. Listed so the switch stays exhaustive and a
      // future enum addition forces a compile error rather than a silent gap.
      throw StateError(
        'tracking-limit method reached HA-countdown branch: $method',
      );
  }

  final minutesToFlip = (thresholdHours - ha) * 60.0;

  if (minutesToFlip <= 0) {
    // Already past the threshold — the watchdog should be flipping right now.
    return MeridianCountdownState(
      isArmed: true,
      timeToFlip: Duration.zero,
      isAutomaticWatchdog: true,
      isSequencerOwned: sequencerActive,
      disabledReason: 'Already past meridian — flip imminent',
      method: method,
      hourAngleHours: ha,
      sideOfPier: sideOfPier,
    );
  }

  // Convert fractional minutes to whole seconds without losing sub-minute
  // precision (so a 4.5-minute countdown reads 4m30s, not 4m).
  final seconds = (minutesToFlip * 60.0).round();
  return MeridianCountdownState(
    isArmed: true,
    timeToFlip: Duration(seconds: seconds),
    isAutomaticWatchdog: true,
    // When a sequence is running the in-sequence node / Rust trigger owns the
    // flip — but we STILL show the numeric countdown so the banner can say
    // "handled automatically by the sequence" alongside the live timer.
    isSequencerOwned: sequencerActive,
    disabledReason: null,
    method: method,
    hourAngleHours: ha,
    sideOfPier: sideOfPier,
  );
}

/// Derived countdown to the next meridian flip, for the capture banner.
///
/// A PURE, synchronous projection: it [ref.watch]es the mount / settings /
/// sequence inputs and recomputes via [computeMeridianCountdown] whenever any of
/// them change (mount slew/connect, location saved, sequence start/stop, settings
/// edit, and the `appSettingsProvider` AsyncLoading→data transition). It never
/// re-runs the standalone monitor, so it has no side effects.
///
/// It holds NO timer. The wall-clock ticking between input changes is driven
/// by the banner widget's lifecycle-bound [kMeridianCountdownTick] timer, which
/// invalidates this provider each tick. The timer belongs to the widget because
/// `State.dispose` cancels it synchronously during teardown; an autoDispose
/// periodic stream here leaks a timer past the end of a widget test.
///
/// `autoDispose` so the projection is dropped the moment no banner is mounted.
final meridianCountdownProvider = Provider.autoDispose<MeridianCountdownState>((
  ref,
) {
  final mount = ref.watch(mountStateProvider);
  final appSettings = ref.watch(appSettingsProvider).valueOrNull;
  final settings = ref.watch(effectiveMeridianFlipSettingsProvider);
  final execState = ref.watch(sequenceExecutionStateProvider);
  final enabled = ref.watch(isMeridianFlipEnabledProvider);

  return computeMeridianCountdown(
    mount: mount,
    longitude: appSettings?.longitude,
    latitude: appSettings?.latitude,
    settings: settings,
    execState: execState,
    enabled: enabled,
  );
});
