import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Dialog showing real-time meridian flip progress
class MeridianFlipProgressDialog extends ConsumerStatefulWidget {
  /// Stream of flip events to display
  final Stream<MeridianFlipEvent> eventStream;

  /// Callback when abort is requested
  final VoidCallback? onAbort;

  const MeridianFlipProgressDialog({
    super.key,
    required this.eventStream,
    this.onAbort,
  });

  @override
  ConsumerState<MeridianFlipProgressDialog> createState() =>
      _MeridianFlipProgressDialogState();
}

class _MeridianFlipProgressDialogState
    extends ConsumerState<MeridianFlipProgressDialog> {
  StreamSubscription<MeridianFlipEvent>? _subscription;

  // State
  String _targetName = 'Unknown';
  PierSide _fromPierSide = PierSide.unknown;
  double _hourAngle = 0.0;
  List<FlipStepState> _steps = [];
  int _currentStepIndex = -1;
  int _progressPercent = 0;
  bool _isComplete = false;
  bool _hasFailed = false;
  String? _errorMessage;
  String? _actionTaken;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;
  Timer? _autoDismissTimer;
  DateTime? _startTime;

  @override
  void initState() {
    super.initState();
    _subscription = widget.eventStream.listen(_handleEvent);
    _startTime = DateTime.now();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_isComplete && !_hasFailed) {
        setState(() {
          _elapsed = DateTime.now().difference(_startTime!);
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _elapsedTimer?.cancel();
    _autoDismissTimer?.cancel();
    super.dispose();
  }

  void _handleEvent(MeridianFlipEvent event) {
    if (!mounted) return;

    setState(() {
      switch (event) {
        case MeridianFlipStarting(
            :final targetName,
            :final fromPierSide,
            :final hourAngle
          ):
          _targetName = targetName;
          _fromPierSide = fromPierSide;
          _hourAngle = hourAngle;

        case MeridianFlipStepStarted(
            :final step,
            :final stepIndex,
            :final totalSteps
          ):
          // Seed pending rows lazily: we do NOT guess each step's FlipStep
          // kind from its index (the old _getStepForIndex hard-coded a 9-step
          // pipeline that silently diverged whenever the backend changed the
          // order or count). Pending rows carry labelKnown=false and render a
          // generic "Step i of N — pending"; the concrete FlipStep label is
          // only set once that step's StepStarted event actually arrives.
          if (_steps.isEmpty) {
            _steps = List.generate(
              totalSteps,
              (i) => FlipStepState(
                step: step,
                status: StepStatus.pending,
                labelKnown: false,
              ),
            );
          }
          // Update current step — this is where the real FlipStep label lands.
          _currentStepIndex = stepIndex;
          if (stepIndex < _steps.length) {
            _steps[stepIndex] = _steps[stepIndex].copyWith(
              step: step,
              status: StepStatus.inProgress,
              labelKnown: true,
            );
          }

        case MeridianFlipStepCompleted(:final durationSecs):
          if (_currentStepIndex >= 0 && _currentStepIndex < _steps.length) {
            _steps[_currentStepIndex] = _steps[_currentStepIndex].copyWith(
              status: StepStatus.completed,
              durationSecs: durationSecs,
            );
          }

        case MeridianFlipStepFailed(:final error):
          if (_currentStepIndex >= 0 && _currentStepIndex < _steps.length) {
            _steps[_currentStepIndex] = _steps[_currentStepIndex].copyWith(
              status: StepStatus.failed,
              error: error,
            );
          }

        case MeridianFlipProgress(:final percent):
          _progressPercent = percent;

        case MeridianFlipRetryScheduled():
          // Could show retry info in UI
          break;

        case MeridianFlipCompleted():
          _isComplete = true;
          _elapsedTimer?.cancel();
          // Owned so we can cancel on dispose — a teardown mid-delay would
          // otherwise leak a pending Timer past the widget tree.
          _autoDismissTimer?.cancel();
          _autoDismissTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) {
              Navigator.of(context).pop(true); // Return success
            }
          });

        case MeridianFlipFailed(:final error, :final actionTaken):
          _hasFailed = true;
          _errorMessage = error;
          _actionTaken = actionTaken;
          _elapsedTimer?.cancel();

        case MeridianFlipAborted(:final reason):
          _hasFailed = true;
          _errorMessage = 'Aborted: $reason';
          _elapsedTimer?.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 500,
      designHeight: 600,
    );

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _buildHeader(colors),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTargetInfo(colors),
                    const SizedBox(height: 20),
                    _buildStepsList(colors),
                    if (_hasFailed) ...[
                      const SizedBox(height: 16),
                      _buildErrorSection(colors),
                    ],
                    const SizedBox(height: 16),
                    _buildProgressBar(colors),
                    const SizedBox(height: 12),
                    _buildFooterInfo(colors),
                  ],
                ),
              ),
            ),
            _buildActions(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(SkotiqColors colors) {
    final statusIcon = _isComplete
        ? LucideIcons.checkCircle
        : _hasFailed
            ? LucideIcons.xCircle
            : LucideIcons.rotateCcw;
    final statusColor = _isComplete
        ? colors.success
        : _hasFailed
            ? colors.error
            : colors.primary;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: SkotiqDecorations.tintedBadge(
              statusColor,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            ),
            child: _isComplete || _hasFailed
                ? Icon(statusIcon, color: statusColor, size: 20)
                : SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: statusColor,
                    ),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isComplete
                      ? 'Meridian Flip Complete'
                      : _hasFailed
                          ? 'Meridian Flip Failed'
                          : 'Meridian Flip in Progress',
                  style:
                      SkotiqTypography.h4.copyWith(color: colors.textPrimary),
                ),
                Text(
                  _isComplete
                      ? 'Resuming sequence...'
                      : _hasFailed
                          ? 'An error occurred'
                          : 'Please wait while the mount flips',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Only offer the header close button once the flip has finished or
          // failed — during the flip the only way out is the Abort button, so
          // a dead no-op "X" would just confuse the operator.
          if (_isComplete || _hasFailed)
            IconButton(
              icon: Icon(LucideIcons.x, color: colors.textMuted, size: 18),
              onPressed: () => Navigator.of(context).pop(_isComplete),
              tooltip: 'Close',
            ),
        ],
      ),
    );
  }

  Widget _buildTargetInfo(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.target, size: 14, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'Target: $_targetName',
                style: SkotiqTypography.labelStrong
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _InfoChip(
                label: 'From',
                value: _pierSideLabel(_fromPierSide),
                colors: colors,
              ),
              const SizedBox(width: 12),
              Icon(LucideIcons.arrowRight, size: 14, color: colors.textMuted),
              const SizedBox(width: 12),
              _InfoChip(
                label: 'To',
                value: _fromPierSide == PierSide.west ? 'East' : 'West',
                colors: colors,
              ),
              const Spacer(),
              _InfoChip(
                label: 'HA',
                value: '${_hourAngle.toStringAsFixed(2)}h',
                colors: colors,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _pierSideLabel(PierSide side) {
    switch (side) {
      case PierSide.east:
        return 'East';
      case PierSide.west:
        return 'West';
      case PierSide.unknown:
        return 'Unknown';
    }
  }

  Widget _buildStepsList(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Steps',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        ..._steps.asMap().entries.map((entry) {
          final index = entry.key;
          final step = entry.value;
          return _StepRow(
            step: step,
            index: index,
            totalSteps: _steps.length,
            isLast: index == _steps.length - 1,
            colors: colors,
          );
        }),
        if (_steps.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                'Initializing...',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildErrorSection(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: SkotiqDecorations.statusChip(
        colors.error,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertCircle, size: 18, color: colors.error),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Error',
                  style: SkotiqTypography.h6.copyWith(color: colors.error),
                ),
                const SizedBox(height: 4),
                Text(
                  _errorMessage ?? 'Unknown error',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textPrimary,
                  ),
                ),
                if (_actionTaken != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Action: $_actionTaken',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textSecondary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(SkotiqColors colors) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
          child: LinearProgressIndicator(
            value: _progressPercent / 100.0,
            backgroundColor: colors.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(
              _hasFailed ? colors.error : colors.primary,
            ),
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '$_progressPercent%',
              style: SkotiqTypography.h6.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFooterInfo(SkotiqColors colors) {
    final elapsedStr = _formatDuration(_elapsed);
    final stepStr = _currentStepIndex >= 0 && _steps.isNotEmpty
        ? 'Step ${_currentStepIndex + 1} of ${_steps.length}'
        : 'Initializing';

    return Row(
      children: [
        Text(
          'Elapsed: $elapsedStr',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: 16),
        Text(
          stepStr,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  Widget _buildActions(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_isComplete) ...[
            SkotiqButton(
              label: 'Done',
              icon: LucideIcons.check,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ] else if (_hasFailed) ...[
            SkotiqButton(
              label: 'Close',
              variant: ButtonVariant.ghost,
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ] else ...[
            SkotiqButton(
              label: 'Abort flip',
              icon: LucideIcons.octagon,
              variant: ButtonVariant.destructive,
              onPressed: () {
                widget.onAbort?.call();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// State for a single flip step
class FlipStepState {
  final FlipStep step;
  final StepStatus status;
  final double? durationSecs;
  final String? error;

  /// Whether [step] is the real FlipStep reported by the backend for this row
  /// (true) versus a placeholder seeded before the step's StepStarted event
  /// arrived (false). Pending rows render a generic "Step i of N" until the
  /// concrete label is known, so the dialog never guesses the pipeline.
  final bool labelKnown;

  const FlipStepState({
    required this.step,
    required this.status,
    this.durationSecs,
    this.error,
    this.labelKnown = true,
  });

  FlipStepState copyWith({
    FlipStep? step,
    StepStatus? status,
    double? durationSecs,
    String? error,
    bool? labelKnown,
  }) {
    return FlipStepState(
      step: step ?? this.step,
      status: status ?? this.status,
      durationSecs: durationSecs ?? this.durationSecs,
      error: error ?? this.error,
      labelKnown: labelKnown ?? this.labelKnown,
    );
  }
}

/// Status of a flip step
enum StepStatus {
  pending,
  inProgress,
  completed,
  failed,
}

/// Widget for displaying a step row
class _StepRow extends StatelessWidget {
  final FlipStepState step;
  final int index;
  final int totalSteps;
  final bool isLast;
  final SkotiqColors colors;

  const _StepRow({
    required this.step,
    required this.index,
    required this.totalSteps,
    required this.isLast,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color iconColor;

    switch (step.status) {
      case StepStatus.pending:
        icon = LucideIcons.circle;
        iconColor = colors.textMuted;
        break;
      case StepStatus.inProgress:
        icon = LucideIcons.loader;
        iconColor = colors.primary;
        break;
      case StepStatus.completed:
        icon = LucideIcons.checkCircle2;
        iconColor = colors.success;
        break;
      case StepStatus.failed:
        icon = LucideIcons.xCircle;
        iconColor = colors.error;
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          step.status == StepStatus.inProgress
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: iconColor,
                  ),
                )
              : Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              // Only show the concrete FlipStep label once the backend has
              // actually started that step; until then it's a generic
              // placeholder so we never mislabel a pending row.
              step.labelKnown
                  ? _stepLabel(step.step)
                  : 'Step ${index + 1} of $totalSteps',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: step.status == StepStatus.pending
                    ? colors.textMuted
                    : colors.textPrimary,
                fontWeight: step.status == StepStatus.inProgress
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
          if (step.durationSecs != null)
            Text(
              '${step.durationSecs!.toStringAsFixed(1)}s',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textMuted,
              ),
            ),
          if (step.status == StepStatus.completed)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: SkotiqDecorations.tintedBadge(
                  colors.success,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  'done',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize9,
                    color: colors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          if (step.status == StepStatus.failed)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: SkotiqDecorations.tintedBadge(
                  colors.error,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  'failed',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize9,
                    color: colors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _stepLabel(FlipStep step) {
    switch (step) {
      case FlipStep.pausingGuider:
        return 'Pausing guider';
      case FlipStep.stoppingTracking:
        return 'Stopping tracking';
      case FlipStep.slewingToTarget:
        return 'Slewing to target (flip)';
      case FlipStep.verifyingPierSide:
        return 'Verifying pier side';
      case FlipStep.resumingTracking:
        return 'Resuming tracking';
      case FlipStep.plateSolvingAndCentering:
        return 'Plate solving and centering';
      case FlipStep.refocusing:
        return 'Running autofocus';
      case FlipStep.resumingGuider:
        return 'Resuming guider';
      case FlipStep.settling:
        return 'Waiting for settle';
    }
  }
}

/// Small info chip widget
class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _InfoChip({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: SkotiqTypography.labelStrongSm
                .copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// Show the meridian flip progress dialog
Future<bool?> showMeridianFlipProgressDialog(
  BuildContext context, {
  required Stream<MeridianFlipEvent> eventStream,
  VoidCallback? onAbort,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false, // Cannot dismiss by clicking outside
    builder: (context) => MeridianFlipProgressDialog(
      eventStream: eventStream,
      onAbort: onAbort,
    ),
  );
}
