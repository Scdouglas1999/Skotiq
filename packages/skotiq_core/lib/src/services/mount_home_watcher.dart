import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart' show MountStatus;

/// How a Home command ended when it did not fail.
enum MountHomeOutcome {
  /// The mount stopped and its driver reports `AtHome`.
  confirmed,

  /// The mount moved and then stopped, but its driver cannot report `AtHome`,
  /// so where it stopped is the driver's word, not a reading.
  unconfirmed,
}

/// A Home command that did not get the mount home.
class MountHomeException implements Exception {
  const MountHomeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Watches a mount after its driver has accepted FindHome and decides whether
/// the mount actually went home.
///
/// A driver returning from FindHome proves nothing. On the owner's PegasusAstro
/// NYX-101 over ASCOM, `CanFindHome` answered true and `FindHome` returned in
/// 0.2 s, and then the mount never moved: `Slewing` stayed false, Dec stayed
/// put for four minutes, RA changed only with sidereal time, and `AtHome`
/// stayed false. Reporting that as "homed" would leave the operator believing
/// the tube was on the pole. So the watcher requires evidence:
///
/// 1. motion must start within [motionStartWindow] — `Slewing` true, or the
///    pointing measurably moved (see [pointingMoved]);
/// 2. the mount must then stop within [completionTimeout];
/// 3. once stopped, `AtHome` decides: true is [MountHomeOutcome.confirmed],
///    false is a failure, and a driver that cannot report it gives
///    [MountHomeOutcome.unconfirmed].
class MountHomeWatcher {
  MountHomeWatcher({
    required this.readStatus,
    this.isCancelled,
    this.motionStartWindow = defaultMotionStartWindow,
    this.completionTimeout = defaultCompletionTimeout,
    this.pollInterval = defaultPollInterval,
    Future<void> Function(Duration)? delay,
    Stopwatch Function()? stopwatch,
  }) : _delay = delay ?? Future<void>.delayed,
       _stopwatch = stopwatch ?? Stopwatch.new;

  /// How long a mount gets to show any motion after FindHome returns.
  ///
  /// Real homes start within a second or two of the command (the simulator,
  /// INDI and OnStep immediately; ASCOM V3 drivers do not even return until
  /// the mount has arrived). Fifteen seconds leaves room for a slow serial
  /// link or a driver that spins up its motors first, while still telling the
  /// operator about a driver that accepted Home and did nothing — the NYX-101
  /// case — long before they would think to check the mount by eye.
  static const Duration defaultMotionStartWindow = Duration(seconds: 15);

  /// How long a home may take from start to stop. Matches the native
  /// find-home timeout (`Timeouts::find_home`, 300 s): a mount still moving
  /// after that is stuck, not homing.
  static const Duration defaultCompletionTimeout = Duration(minutes: 5);

  /// Status poll cadence while homing; the same cadence slews use.
  static const Duration defaultPollInterval = Duration(milliseconds: 500);

  /// Smallest pointing change, in degrees, that counts as motion. Well above
  /// encoder and refraction-model jitter on a stopped mount, well below what a
  /// home moves in its first second.
  static const double motionThresholdDegrees = 0.1;

  /// Sidereal hours that pass per elapsed SI second.
  static const double _siderealHoursPerSecond = 1.00273790935 / 3600.0;

  static const String didNotMoveMessage =
      "The mount's driver accepted Home but the mount didn't move.";
  static const String stoppedShortMessage =
      'The mount stopped but does not report being at home.';
  static const String cancelledMessage =
      'Homing was stopped before the mount reached home.';

  final Future<MountStatus> Function() readStatus;

  /// Returns true once the operator has stopped the home (Abort slew).
  final bool Function()? isCancelled;

  final Duration motionStartWindow;
  final Duration completionTimeout;
  final Duration pollInterval;
  final Future<void> Function(Duration) _delay;
  final Stopwatch Function() _stopwatch;

  /// Whether the mount's pointing between [before] and [after], [elapsed]
  /// apart, shows the axes turned.
  ///
  /// Dec moving is motion. RA alone is not: a stopped mount that is not
  /// tracking keeps its hour angle and drifts in RA with the sky (exactly what
  /// the NYX-101 did), while a stopped mount that is tracking keeps its RA.
  /// Only a mount whose axes are turning changes both RA and hour angle.
  static bool pointingMoved(
    MountStatus before,
    MountStatus after,
    Duration elapsed,
  ) {
    if ((after.declination - before.declination).abs() >
        motionThresholdDegrees) {
      return true;
    }
    final deltaRaHours = _wrapHours(
      after.rightAscension - before.rightAscension,
    );
    final siderealHours =
        elapsed.inMicroseconds / 1e6 * _siderealHoursPerSecond;
    final deltaHaHours = _wrapHours(siderealHours - deltaRaHours);
    const thresholdHours = motionThresholdDegrees / 15.0;
    return deltaRaHours.abs() > thresholdHours &&
        deltaHaHours.abs() > thresholdHours;
  }

  /// Whether this status carries a real `AtHome` reading.
  static bool reportsAtHome(MountStatus status) =>
      status.availability['at_home'] == 'available';

  static double _wrapHours(double hours) {
    final wrapped = (hours + 12.0) % 24.0;
    return (wrapped < 0 ? wrapped + 24.0 : wrapped) - 12.0;
  }

  /// Watch from [before], the status read just before FindHome was sent.
  ///
  /// Throws [MountHomeException] when the mount never moved, never stopped,
  /// was stopped by the operator, or stopped somewhere its driver says is not
  /// home.
  Future<MountHomeOutcome> watch(MountStatus before) async {
    final clock = _stopwatch()..start();
    var moved = false;
    while (true) {
      _throwIfCancelled();
      final status = await readStatus();
      _throwIfCancelled();

      // A mount already sitting at home has nowhere to go: its driver
      // returns from FindHome without moving and still reports AtHome.
      if (!moved &&
          !status.slewing &&
          reportsAtHome(before) &&
          before.atHome &&
          reportsAtHome(status) &&
          status.atHome) {
        return MountHomeOutcome.confirmed;
      }

      if (!moved) {
        moved =
            status.slewing ||
            (reportsAtHome(status) && status.atHome && !before.atHome) ||
            pointingMoved(before, status, clock.elapsed);
        if (!moved && clock.elapsed >= motionStartWindow) {
          throw const MountHomeException(didNotMoveMessage);
        }
      }

      if (moved && !status.slewing) {
        if (!reportsAtHome(status)) return MountHomeOutcome.unconfirmed;
        if (status.atHome) return MountHomeOutcome.confirmed;
        throw const MountHomeException(stoppedShortMessage);
      }

      if (clock.elapsed >= completionTimeout) {
        throw MountHomeException(
          'The mount was still moving ${completionTimeout.inMinutes} minutes '
          'after Home was sent. Check the mount before commanding it again.',
        );
      }
      await _delay(pollInterval);
    }
  }

  void _throwIfCancelled() {
    final cancelled = isCancelled;
    if (cancelled != null && cancelled()) {
      throw const MountHomeException(cancelledMessage);
    }
  }
}

/// Builds the watcher a Home command uses.
typedef MountHomeWatcherFactory =
    MountHomeWatcher Function({
      required Future<MountStatus> Function() readStatus,
      bool Function()? isCancelled,
    });

/// The watcher factory the device service homes with. Overridden in tests to
/// shrink the motion window and poll cadence; production keeps the defaults.
final mountHomeWatcherFactoryProvider = Provider<MountHomeWatcherFactory>(
  (ref) =>
      ({required readStatus, isCancelled}) =>
          MountHomeWatcher(readStatus: readStatus, isCancelled: isCancelled),
);
