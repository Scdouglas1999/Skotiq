import 'meridian_flip_event.dart' show FlipStep;

/// Current flip state for UI
///
/// Represents the current state of a meridian flip operation.
enum FlipExecutionState {
  /// No flip is in progress
  idle,

  /// Flip is currently executing
  executing,

  /// Flip failed and is being retried
  retrying,

  /// Flip completed successfully
  completed,

  /// Flip failed after all retries
  failed,

  /// Flip was aborted by user
  aborted,
}

/// Where the flip a mount's flip monitor runs stands, as the mount card
/// shows it: one value, so the host shares all of it with linked clients.
class FlipMonitorProgress {
  const FlipMonitorProgress({
    required this.state,
    required this.attempt,
    required this.step,
    required this.percent,
    required this.error,
  });

  /// No flip.
  static const none = FlipMonitorProgress(
    state: FlipExecutionState.idle,
    attempt: 0,
    step: null,
    percent: 0,
    error: null,
  );

  final FlipExecutionState state;
  final int attempt;
  final FlipStep? step;

  /// 0 to 100.
  final int percent;
  final String? error;

  FlipMonitorProgress copyWith({
    FlipExecutionState? state,
    int? attempt,
    FlipStep? step,
    bool clearStep = false,
    int? percent,
    String? error,
    bool clearError = false,
  }) => FlipMonitorProgress(
    state: state ?? this.state,
    attempt: attempt ?? this.attempt,
    step: clearStep ? null : step ?? this.step,
    percent: percent ?? this.percent,
    error: clearError ? null : error ?? this.error,
  );

  /// The flip ended as [outcome] (failed or aborted) with [error]. A flip
  /// under way keeps the attempt, step and progress it reached; one that
  /// ended before it started shows none, not the flip before it.
  FlipMonitorProgress ended(FlipExecutionState outcome, String? error) {
    final underway =
        state == FlipExecutionState.executing ||
        state == FlipExecutionState.retrying;
    return FlipMonitorProgress(
      state: outcome,
      attempt: underway ? attempt : 0,
      step: underway ? step : null,
      percent: underway ? percent : 0,
      error: error,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FlipMonitorProgress &&
      other.state == state &&
      other.attempt == attempt &&
      other.step == step &&
      other.percent == percent &&
      other.error == error;

  @override
  int get hashCode => Object.hash(state, attempt, step, percent, error);

  Map<String, dynamic> toJson() => {
    'state': state.name,
    'attempt': attempt,
    'step': step?.name,
    'progress': percent,
    'error': error,
  };

  /// An unknown state reads as idle and an unknown step as none. Throws
  /// [FormatException] when the attempt or percent is missing.
  factory FlipMonitorProgress.fromJson(Map<String, dynamic> json) {
    int count(String key) {
      final value = json[key];
      if (value is num) return value.toInt();
      throw FormatException('Flip progress has no integer "$key"');
    }

    final error = json['error'];
    return FlipMonitorProgress(
      state: FlipExecutionState.values.firstWhere(
        (s) => s.name == json['state'],
        orElse: () => FlipExecutionState.idle,
      ),
      attempt: count('attempt'),
      step: FlipStep.values.where((s) => s.name == json['step']).firstOrNull,
      percent: count('progress'),
      error: error is String ? error : null,
    );
  }
}
