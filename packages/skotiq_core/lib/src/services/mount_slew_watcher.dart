import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations;

import '../backend/skotiq_backend.dart' show MountStatus;

/// Where a slew stands at one status read.
class MountSlewProgress {
  const MountSlewProgress({
    required this.targetRa,
    required this.targetDec,
    required this.rightAscension,
    required this.declination,
    required this.remainingDegrees,
    required this.initialDegrees,
    required this.slewing,
    required this.elapsed,
  });

  /// The commanded target, J2000 hours and degrees.
  final double targetRa;
  final double targetDec;

  /// Where the mount reports it is pointing.
  final double rightAscension;
  final double declination;

  /// Arc between the mount and the target, in degrees.
  final double remainingDegrees;

  /// Arc between the mount and the target at the first read.
  final double initialDegrees;

  /// The driver's `Slewing` flag at this read.
  final bool slewing;

  final Duration elapsed;

  /// Share of the arc covered, 0 to 1. Null when there was nothing to cover.
  double? get fraction {
    if (initialDegrees <= 0) return null;
    return (1 - remainingDegrees / initialDegrees).clamp(0.0, 1.0);
  }
}

/// A slew that ended without the mount arriving at its target.
class MountSlewException implements Exception {
  const MountSlewException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Watches a mount after its driver has accepted a slew and decides when the
/// slew is over.
///
/// A driver accepting the command says only that the slew has started.
/// ASCOM's `SlewToCoordinatesAsync`, Alpaca and the headless API all return
/// at once, and right after the call an ASCOM driver can still report
/// `Slewing == false` because its mount has not begun to move. Reading that
/// flag once and calling the slew complete reports an arrival while the mount
/// is still on its way. So the watcher needs evidence of motion and of a stop:
///
/// 1. the slew counts as underway once `Slewing` has read true, or the mount
///    has measurably closed on the target;
/// 2. it is over once `Slewing` reads false on [idleConfirmPolls] reads in a
///    row and the pointing has stopped changing;
/// 3. it arrived when the mount then sits within [arrivalToleranceDegrees] of
///    the target. A mount that was already there and never reports moving is
///    accepted only after [startGrace], long enough for a lagging `Slewing`
///    flag to have turned true;
/// 4. a mount that shows no motion within [motionStartWindow], stops short,
///    stops answering or is still moving after [completionTimeout] fails the
///    slew with a message that says which.
///
/// The target is J2000, and a mount may report its position in the
/// coordinates of the date instead; the distance is measured to whichever of
/// the two the mount is nearer, which is never ambiguous because the two
/// frames differ by a fraction of a degree.
class MountSlewWatcher {
  MountSlewWatcher({
    required this.readStatus,
    required this.targetRa,
    required this.targetDec,
    this.isCancelled,
    this.onProgress,
    this.startGrace = defaultStartGrace,
    this.motionStartWindow = defaultMotionStartWindow,
    this.completionTimeout = defaultCompletionTimeout,
    this.pollInterval = defaultPollInterval,
    this.idleConfirmPolls = defaultIdleConfirmPolls,
    this.arrivalToleranceDegrees = defaultArrivalToleranceDegrees,
    this.maxConsecutiveReadFailures = defaultMaxConsecutiveReadFailures,
    DateTime? now,
    Future<void> Function(Duration)? delay,
    Stopwatch Function()? stopwatch,
  }) : _delay = delay ?? Future<void>.delayed,
       _stopwatch = stopwatch ?? Stopwatch.new {
    final (raDeg, decDeg) = AstronomyCalculations.precessFromJ2000ToDate(
      raDeg: targetRa * 15.0,
      decDeg: targetDec,
      dt: (now ?? DateTime.now()).toUtc(),
    );
    _targetOfDate = (raDeg / 15.0, decDeg);
  }

  /// How long a mount that never reports `Slewing` must sit idle on the
  /// target before the slew counts as done. ASCOM drivers turn `Slewing` true
  /// within a few hundred milliseconds of an async slew.
  static const Duration defaultStartGrace = Duration(seconds: 2);

  /// How long a mount gets to show any motion toward the target.
  static const Duration defaultMotionStartWindow = Duration(seconds: 15);

  /// Matches the native GoTo timeout (`Timeouts::long_slew`, 300 s).
  static const Duration defaultCompletionTimeout = Duration(minutes: 5);

  static const Duration defaultPollInterval = Duration(milliseconds: 500);

  static const int defaultIdleConfirmPolls = 2;

  /// A GoTo lands within arcminutes of its target in the mount's own
  /// coordinates; a quarter of a degree is a miss, not pointing error.
  static const double defaultArrivalToleranceDegrees = 0.25;

  /// Six failed reads at the default cadence is three seconds without an
  /// answer from a mount that should be reporting its slew.
  static const int defaultMaxConsecutiveReadFailures = 6;

  /// How far the mount must close on the target to count as moving.
  static const double motionThresholdDegrees = 0.1;

  /// Largest change in distance between two reads of a stopped mount. An
  /// untracked mount drifts with the sky by about 0.002 degrees per read.
  static const double stillThresholdDegrees = 0.01;

  static const String cancelledMessage =
      'The slew was stopped before the mount reached the target.';
  static const String didNotMoveMessage =
      "The mount's driver accepted the slew but the mount didn't move.";

  final Future<MountStatus> Function() readStatus;

  /// The commanded target, J2000 hours and degrees.
  final double targetRa;
  final double targetDec;

  /// Returns true once the slew should no longer be watched (Abort slew).
  final bool Function()? isCancelled;

  final void Function(MountSlewProgress progress)? onProgress;

  final Duration startGrace;
  final Duration motionStartWindow;
  final Duration completionTimeout;
  final Duration pollInterval;
  final int idleConfirmPolls;
  final double arrivalToleranceDegrees;
  final int maxConsecutiveReadFailures;
  final Future<void> Function(Duration) _delay;
  final Stopwatch Function() _stopwatch;
  late final (double, double) _targetOfDate;

  /// Great-circle separation between two RA (hours) / Dec (degrees) points.
  static double separationDegrees(
    double ra1,
    double dec1,
    double ra2,
    double dec2,
  ) {
    const toRad = math.pi / 180.0;
    final a1 = ra1 * 15.0 * toRad;
    final d1 = dec1 * toRad;
    final a2 = ra2 * 15.0 * toRad;
    final d2 = dec2 * toRad;
    final cosSep =
        math.sin(d1) * math.sin(d2) +
        math.cos(d1) * math.cos(d2) * math.cos(a2 - a1);
    return math.acos(cosSep.clamp(-1.0, 1.0)) / toRad;
  }

  /// Distance from [status]'s pointing to the target, in whichever frame the
  /// mount is nearer.
  double remainingDegrees(MountStatus status) {
    final j2000 = separationDegrees(
      status.rightAscension,
      status.declination,
      targetRa,
      targetDec,
    );
    final ofDate = separationDegrees(
      status.rightAscension,
      status.declination,
      _targetOfDate.$1,
      _targetOfDate.$2,
    );
    return math.min(j2000, ofDate);
  }

  /// Watch until the slew is over. Returns the final status read when the
  /// mount arrived; throws [MountSlewException] otherwise.
  Future<MountStatus> watch() async {
    final clock = _stopwatch()..start();
    var seenSlewing = false;
    var idlePolls = 0;
    var failures = 0;
    double? initial;
    double? previous;
    while (true) {
      _throwIfCancelled();
      final MountStatus status;
      try {
        status = await readStatus();
        failures = 0;
      } catch (e) {
        failures++;
        if (failures >= maxConsecutiveReadFailures) {
          throw MountSlewException(
            'Lost contact with the mount during the slew: $e',
          );
        }
        _checkTimeout(clock.elapsed);
        await _delay(pollInterval);
        continue;
      }
      _throwIfCancelled();

      final remaining = remainingDegrees(status);
      final start = initial ??= remaining;
      if (status.slewing) {
        seenSlewing = true;
        idlePolls = 0;
      } else {
        idlePolls++;
      }
      final near = remaining <= arrivalToleranceDegrees;
      final moved = remaining < start - motionThresholdDegrees;
      final still =
          previous != null &&
          (remaining - previous).abs() < stillThresholdDegrees;
      previous = remaining;

      onProgress?.call(
        MountSlewProgress(
          targetRa: targetRa,
          targetDec: targetDec,
          rightAscension: status.rightAscension,
          declination: status.declination,
          remainingDegrees: remaining,
          initialDegrees: start,
          slewing: status.slewing,
          elapsed: clock.elapsed,
        ),
      );

      if (idlePolls >= idleConfirmPolls && still) {
        if (near && (seenSlewing || moved || clock.elapsed >= startGrace)) {
          return status;
        }
        if (!near && (seenSlewing || moved)) {
          throw MountSlewException(
            'The mount stopped ${formatSlewDistance(remaining)} from the '
            'target.',
          );
        }
      }

      if (!seenSlewing &&
          !moved &&
          !near &&
          clock.elapsed >= motionStartWindow) {
        throw const MountSlewException(didNotMoveMessage);
      }
      _checkTimeout(clock.elapsed);
      await _delay(pollInterval);
    }
  }

  void _checkTimeout(Duration elapsed) {
    if (elapsed >= completionTimeout) {
      throw MountSlewException(
        'The mount was still moving ${completionTimeout.inMinutes} minutes '
        'after the slew was sent. Check the mount before commanding it again.',
      );
    }
  }

  void _throwIfCancelled() {
    final cancelled = isCancelled;
    if (cancelled != null && cancelled()) {
      throw const MountSlewException(cancelledMessage);
    }
  }
}

/// An arc on the sky for a slew readout: degrees from one degree up,
/// arcminutes below that.
String formatSlewDistance(double degrees) => degrees >= 1
    ? '${degrees.toStringAsFixed(1)}°'
    : "${(degrees * 60).toStringAsFixed(1)}'";

/// Builds the watcher a slew command uses.
typedef MountSlewWatcherFactory =
    MountSlewWatcher Function({
      required Future<MountStatus> Function() readStatus,
      required double targetRa,
      required double targetDec,
      bool Function()? isCancelled,
      void Function(MountSlewProgress progress)? onProgress,
    });

/// The watcher factory the device service slews with. Overridden in tests to
/// shrink the windows and poll cadence; production keeps the defaults.
final mountSlewWatcherFactoryProvider = Provider<MountSlewWatcherFactory>(
  (ref) =>
      ({
        required readStatus,
        required targetRa,
        required targetDec,
        isCancelled,
        onProgress,
      }) => MountSlewWatcher(
        readStatus: readStatus,
        targetRa: targetRa,
        targetDec: targetDec,
        isCancelled: isCancelled,
        onProgress: onProgress,
      ),
);

/// The slew the device service is watching, or null when none is in flight.
/// Slew controls read it to show how far the mount still has to go.
final mountSlewProgressProvider = StateProvider<MountSlewProgress?>(
  (ref) => null,
);
