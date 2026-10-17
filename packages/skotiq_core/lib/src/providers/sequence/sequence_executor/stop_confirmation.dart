import 'dart:async';

/// How long a finalization waits for the native executor to report an
/// authoritative terminal state after it accepted a stop command.
///
/// Generous on purpose: aborting an in-flight exposure and transitioning the
/// native state machine takes well under a second on real hardware, so this only
/// expires when the terminal is never coming. Expiry is NOT treated as
/// "stopped" — the caller settles to the controllable `stopFailed` state with
/// everything retained.
const Duration kNativeStopConfirmationTimeout = Duration(seconds: 30);

/// How often [NativeStopConfirmer] asks the native executor for its own state
/// while waiting for the terminal event.
///
/// The event remains the fast path — the poll only has to notice a terminal
/// that no event will ever deliver (the headless load->start path installs no
/// Dart-side subscription at all; a lagged broadcast channel drops the event on
/// the owned path). A quarter second keeps an operator-visible Stop feeling
/// immediate while costing at most a handful of cheap status reads.
const Duration kNativeStopConfirmationPollInterval = Duration(
  milliseconds: 250,
);

/// Native executor states that mean the run is over and the hardware is no
/// longer being driven by it. Matched case-insensitively.
///
/// This is an ALLOW-list of terminals, deliberately the opposite direction to
/// the deny-list the stop endpoint uses for "was anything running". The two
/// answer different questions and must fail in opposite directions: that one
/// must treat an unknown state as running (so a stop still acts); this one must
/// treat an unknown state as NOT terminal (so an unrecognised state can never
/// be mistaken for "the camera has stopped exposing"). A new native state added
/// later therefore keeps us waiting rather than tearing down.
const Set<String> kNativeTerminalStates = {
  'idle',
  'completed',
  'failed',
  'cancelled',
  'stopped',
  'error',
};

/// The confirmable stop state a finalization owns, as
/// [NativeStopConfirmer] needs to see it.
///
/// The confirmer both reads and sets [nativeStopConfirmed], so the flag and the
/// completer stay in lockstep with the terminal-event path that shares them.
abstract interface class NativeStopConfirmationTarget {
  /// True once the native executor is confirmed stopped (or was never running).
  bool get nativeStopConfirmed;
  set nativeStopConfirmed(bool value);
}

/// Waits for authoritative confirmation that the native executor has
/// terminated, from EITHER of the two sources that can give it.
///
/// The pushed terminal event completes [NativeStopConfirmer.awaitTermination]'s
/// completer; the status poll is the same executor answering "are you still
/// running?", pulled instead of pushed. Both are authoritative, and each covers
/// a case the other cannot: the headless `POST /api/sequencer/load` ->
/// `/api/sequencer/start` path installs no Dart-side event subscription at all,
/// and the native event channel is a `tokio::sync::broadcast` whose receiver
/// handles `RecvError::Lagged` by SKIPPING events.
///
/// The wait is BOUNDED. Waiting for the terminal is correct — the stop command
/// returning only means it was accepted, and tearing down while the camera may
/// still be exposing is what this gate prevents — but an unbounded wait turns a
/// terminal that never arrives into a Stop button that never returns.
///
/// A status read that throws is treated as "no answer yet", never as
/// confirmation: a backend we cannot reach tells us nothing about the camera.
class NativeStopConfirmer {
  NativeStopConfirmer({
    required Future<String> Function() readNativeState,
    required void Function(String message) logInfo,
    required void Function(String message) logDebug,
    this.timeout = kNativeStopConfirmationTimeout,
    this.pollInterval = kNativeStopConfirmationPollInterval,
  }) : _readNativeState = readNativeState,
       _logInfo = logInfo,
       _logDebug = logDebug;

  /// Reads the native executor's own reported state.
  final Future<String> Function() _readNativeState;
  final void Function(String message) _logInfo;
  final void Function(String message) _logDebug;

  /// Total window before the wait gives up and the caller settles to
  /// `stopFailed`.
  final Duration timeout;

  /// Interval between status polls while waiting for the terminal event.
  final Duration pollInterval;

  /// Block until [target] is confirmed stopped, or throw [TimeoutException]
  /// when neither source confirms inside [timeout].
  ///
  /// [confirmation] is the completer the terminal-event handler completes; this
  /// method completes it too when the poll gets there first, so a later retry
  /// sees a settled confirmation either way.
  Future<void> awaitTermination(
    NativeStopConfirmationTarget target,
    Completer<void> confirmation,
  ) async {
    final deadline = DateTime.now().add(timeout);
    var loggedPollConfirmation = false;
    var loggedPollFailure = false;

    while (true) {
      if (confirmation.isCompleted || target.nativeStopConfirmed) {
        // Keep the completer and the flag in lockstep so a later retry (and
        // the terminal-event guard) sees a settled confirmation either way.
        target.nativeStopConfirmed = true;
        if (!confirmation.isCompleted) confirmation.complete();
        if (loggedPollConfirmation) {
          _logInfo(
            'Finalization: native executor reported a terminal state on the '
            'status poll; treating the stop as confirmed without waiting for '
            'the terminal event.',
          );
        }
        return;
      }

      final remaining = deadline.difference(DateTime.now());
      if (!remaining.isNegative) {
        try {
          // Bounded by whatever is left of the window. The whole point of this
          // gate is that Stop always answers: a status read that hangs (dead
          // remote host, wedged driver) must not be able to outlive the
          // confirmation window and resurrect the never-returning Stop button
          // this timeout exists to prevent.
          final probe = remaining < pollInterval ? remaining : pollInterval;
          final state = await _readNativeState().timeout(probe);
          if (kNativeTerminalStates.contains(state.toLowerCase())) {
            loggedPollConfirmation = true;
            target.nativeStopConfirmed = true;
            if (!confirmation.isCompleted) confirmation.complete();
            continue;
          }
        } catch (e) {
          // Unreachable backend / transport hiccup / slow read. Say nothing
          // about the hardware; let the event (or a later poll) answer. Logged
          // once so a persistently unreachable backend is visible without
          // spraying a line per tick for the whole window.
          if (!loggedPollFailure) {
            loggedPollFailure = true;
            _logDebug(
              'Finalization: stop-confirmation status poll failed ($e); '
              'falling back to the terminal event for confirmation.',
            );
          }
        }
      }

      final left = deadline.difference(DateTime.now());
      if (left.isNegative || left == Duration.zero) {
        if (confirmation.isCompleted || target.nativeStopConfirmed) continue;
        throw TimeoutException(
          'The native executor accepted the stop command but never reported '
          'a terminal state within '
          '${timeout.inSeconds}s. The hardware was NOT '
          'confirmed stopped, so nothing has been torn down.',
          timeout,
        );
      }

      // Wake on whichever comes first: the pushed terminal event, or the next
      // poll tick. The event path stays as immediate as it always was.
      final wait = left < pollInterval ? left : pollInterval;
      await confirmation.future.timeout(wait, onTimeout: () {});
    }
  }
}
