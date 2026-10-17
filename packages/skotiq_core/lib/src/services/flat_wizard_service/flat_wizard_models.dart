part of '../flat_wizard_service.dart';

/// Result of a flat frame calibration for a single filter
class FlatResult {
  final String filter;
  final double exposure;
  final double adu;
  final bool success;
  final int iterations;
  final String? errorMessage;

  /// True when calibration stopped because a cancel was requested (as opposed
  /// to a hardware/convergence failure). A cancelled result is never
  /// `success`, but the caller must distinguish it from a genuine failure so
  /// the run reports "Cancelled" rather than "failed" and does not mark the
  /// filter as failed.
  final bool cancelled;

  /// True when the ENTIRE run must stop, not just this filter: the calibration
  /// exposure timed out or the camera's post-abort idle state could not be
  /// confirmed, so it is unsafe to start any further exposure. A plain
  /// `!success` (e.g. failed to converge) lets the run continue to the next
  /// filter; [haltRun] does not.
  final bool haltRun;

  /// True when the camera's state is UNKNOWN after a failed abort/settle — the
  /// operator must be told to check the hardware before retrying.
  final bool cameraStateUnknown;

  const FlatResult({
    required this.filter,
    required this.exposure,
    required this.adu,
    required this.success,
    this.iterations = 0,
    this.errorMessage,
    this.cancelled = false,
    this.haltRun = false,
    this.cameraStateUnknown = false,
  });

  FlatResult copyWith({
    String? filter,
    double? exposure,
    double? adu,
    bool? success,
    int? iterations,
    String? errorMessage,
    bool? cancelled,
    bool? haltRun,
    bool? cameraStateUnknown,
  }) {
    return FlatResult(
      filter: filter ?? this.filter,
      exposure: exposure ?? this.exposure,
      adu: adu ?? this.adu,
      success: success ?? this.success,
      iterations: iterations ?? this.iterations,
      errorMessage: errorMessage ?? this.errorMessage,
      cancelled: cancelled ?? this.cancelled,
      haltRun: haltRun ?? this.haltRun,
      cameraStateUnknown: cameraStateUnknown ?? this.cameraStateUnknown,
    );
  }
}

/// Cooperative cancellation token threaded through the flat-capture lifecycle.
///
/// A single token is created per capture run by [FlatWizardNotifier.runCapture]
/// and passed down into every [FlatWizardService] call. Cancellation is
/// cooperative: callers poll [isCancelled] between hardware operations, and the
/// in-flight exposure wait races [whenCancelled] so a cancel that arrives
/// mid-exposure aborts the hardware promptly instead of waiting out a fixed
/// delay.
class FlatCancelToken {
  bool _cancelled = false;
  final Completer<void> _completer = Completer<void>();

  /// Whether a cancel has been requested.
  bool get isCancelled => _cancelled;

  /// Completes the first time [cancel] is called. Used to race against an
  /// in-flight exposure-completion event so cancellation is not blocked by a
  /// long exposure.
  Future<void> get whenCancelled => _completer.future;

  /// Request cancellation. Idempotent — the second and later calls are no-ops
  /// so [whenCancelled] completes exactly once.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Terminal outcome of a single authoritative frame capture.
enum FlatFrameOutcome {
  /// Exposure completed and an image was retrieved.
  completed,

  /// Exposure completed/failed but no usable image was produced, or the
  /// hardware reported an explicit failure.
  failed,

  /// A cancel was requested; the exposure was aborted (or never started).
  cancelled,

  /// No terminal completion event arrived within the bounded wait.
  timedOut,
}

/// Result of [FlatWizardService.exposeAndAwait]: the authoritative outcome plus
/// the retrieved image (on [FlatFrameOutcome.completed]) and its mean ADU.
class FlatFrameCapture {
  final FlatFrameOutcome outcome;
  final CapturedImageResult? image;
  final String? error;

  /// Whether the camera is CONFIRMED idle/quiescent after this frame. A
  /// completed or failed frame reached a terminal event, so the camera is
  /// provably idle. For a timed-out or cancelled frame this reflects whether
  /// abort + a bounded settle wait was confirmed: when false the camera's state
  /// is UNKNOWN and the run must stop rather than risk overlapping the next
  /// exposure with a still-active one.
  final bool cameraQuiescent;

  const FlatFrameCapture({
    required this.outcome,
    this.image,
    this.error,
    this.cameraQuiescent = true,
  });

  /// Mean ADU of the retrieved frame, or null when no image was produced.
  double? get adu => image?.stats.mean;

  bool get isCompleted => outcome == FlatFrameOutcome.completed;
  bool get isCancelled => outcome == FlatFrameOutcome.cancelled;
  bool get isTimedOut => outcome == FlatFrameOutcome.timedOut;
}

/// Classification of an incoming event relative to an in-flight exposure.
enum _ExposureEventKind { completedOk, failed, cancelled, notTerminal }

/// Internal union describing which of the three racing sources woke the
/// exposure wait in [FlatWizardService.exposeAndAwait]: a terminal event, a
/// cancel request, or the overall timeout.
class _CaptureWake {
  final _ExposureEventKind? kind;
  final bool isTimeout;

  const _CaptureWake._(this.kind, this.isTimeout);

  factory _CaptureWake.event(_ExposureEventKind k) => _CaptureWake._(k, false);
  factory _CaptureWake.cancel() => const _CaptureWake._(null, false);
  factory _CaptureWake.timeout() => const _CaptureWake._(null, true);

  /// The cancel branch fired (no event, not a timeout).
  bool get isCancel => kind == null && !isTimeout;
}

/// Helper function to convert bin values to BinningMode
BinningMode _binningFromInts(int x, int y) {
  if (x == 1 && y == 1) return BinningMode.one;
  if (x == 2 && y == 2) return BinningMode.two;
  if (x == 3 && y == 3) return BinningMode.three;
  if (x == 4 && y == 4) return BinningMode.four;
  return BinningMode.one;
}
