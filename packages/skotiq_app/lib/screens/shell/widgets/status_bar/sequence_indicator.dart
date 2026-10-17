part of '../status_bar.dart';

/// The run-state pill: the first thing in the instrument bar and the app's one
/// answer to "is it running?".
///
/// 04 §8 pins that: exactly ONE element on any screen is named "Idle", "Ready"
/// or "Running", and it is this. Nothing else in the chrome repeats it.
class _SequenceIndicator extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final SkotiqLocalizations l10n;
  final VoidCallback onTap;

  const _SequenceIndicator({
    required this.colors,
    required this.l10n,
    required this.onTap,
  });

  @override
  ConsumerState<_SequenceIndicator> createState() => _SequenceIndicatorState();
}

class _SequenceIndicatorState extends ConsumerState<_SequenceIndicator> {
  @override
  Widget build(BuildContext context) {
    final executionState = ref.watch(sequenceExecutionStateProvider);
    // Same rule as the LST chip next door: watch what is DISPLAYED. While a run
    // is in flight the executor republishes progress every second
    // (`_startPerRunTimers`), and most of what moves in it — elapsed seconds,
    // the smoothed ETA — is not on this pill. Whole-watching it rebuilt the pill
    // once a second for the length of a night, and on an embedder with no
    // damage region that is a full-window repaint each time.
    //
    // The percentage is rounded INSIDE the selector, so the pill rebuilds when
    // the integer it prints changes, not when the underlying double drifts.
    final progress = ref.watch(
      sequenceProgressProvider.select(
        (p) => (
          hasExposures: p.totalExposures > 0,
          percent: (p.progressPercent * 100).round(),
          currentTarget: p.currentTarget ?? '',
          currentNodeName: p.currentNodeName ?? '',
          message: p.message ?? '',
        ),
      ),
    );
    final statusText = _statusText(executionState);
    final isRunning = executionState == SequenceExecutionState.running;
    final progressPercent = progress.hasExposures ? progress.percent : null;
    // The percentage rides on the pill only while a run is actually in
    // flight; "Completed 100%" and "Idle 0%" are two words where one is true.
    final displayText = progressPercent != null &&
            executionState != SequenceExecutionState.idle &&
            executionState != SequenceExecutionState.completed &&
            executionState != SequenceExecutionState.failed
        ? '$statusText $progressPercent%'
        : statusText;
    final tooltipLines = <String>[
      statusText,
      if (progress.currentTarget.isNotEmpty)
        widget.l10n.text(
          'statusSequenceTarget',
          params: {'name': progress.currentTarget},
        ),
      if (progress.currentNodeName.isNotEmpty)
        widget.l10n.text(
          'statusSequenceStep',
          params: {'name': progress.currentNodeName},
        ),
      if (progress.message.isNotEmpty) progress.message,
    ];

    return Tooltip(
      message: tooltipLines.join('\n'),
      child: InstrumentPill(
        dotTone: _tone(executionState),
        // A ring, not a pulse. This pill is on screen on every route, and the
        // old animated dot repainted the whole bar at ~60 Hz for the length of
        // a run to produce a fade nobody was watching.
        live: isRunning,
        value: displayText,
        semanticLabel: displayText,
        onTap: widget.onTap,
      ),
    );
  }

  InstrumentTone _tone(SequenceExecutionState state) {
    switch (state) {
      case SequenceExecutionState.idle:
        return InstrumentTone.idle;
      case SequenceExecutionState.running:
        return InstrumentTone.success;
      case SequenceExecutionState.paused:
        return InstrumentTone.warning;
      case SequenceExecutionState.stopping:
        return InstrumentTone.error;
      case SequenceExecutionState.completed:
        return InstrumentTone.primary;
      case SequenceExecutionState.failed:
        return InstrumentTone.error;
      case SequenceExecutionState.recovering:
        // Recovery is its own visible state. The error colour says
        // "something is wrong, the sequence is fighting through it" — the
        // same colour as the recovery banner.
        return InstrumentTone.error;
      case SequenceExecutionState.stopFailed:
        // Native stop failed — hardware may still be imaging.
        return InstrumentTone.error;
      case SequenceExecutionState.cleanupFailed:
        // Hardware stopped; session save failed and needs a retry.
        return InstrumentTone.warning;
      case SequenceExecutionState.finalizing:
        // Run ended, durable cleanup wrapping up — calm, transient.
        return InstrumentTone.primary;
    }
  }

  String _statusText(SequenceExecutionState state) {
    final l10n = widget.l10n;
    switch (state) {
      case SequenceExecutionState.idle:
        return l10n.text('idle');
      case SequenceExecutionState.running:
        return l10n.text('sequenceRunning');
      case SequenceExecutionState.paused:
        return l10n.text('sequencePaused');
      case SequenceExecutionState.stopping:
        return l10n.text('statusSequenceStopping');
      case SequenceExecutionState.completed:
        return l10n.text('statusSequenceCompleted');
      case SequenceExecutionState.failed:
        return l10n.text('statusSequenceFailed');
      case SequenceExecutionState.recovering:
        return l10n.text('statusSequenceRecovering');
      case SequenceExecutionState.stopFailed:
        return l10n.text('statusSequenceStopFailed');
      case SequenceExecutionState.cleanupFailed:
        return l10n.text('statusSequenceCleanupFailed');
      case SequenceExecutionState.finalizing:
        return l10n.text('statusSequenceFinalizing');
    }
  }
}
