part of 'plan_targets_tab.dart';

enum _AutopilotAction { start, pause, resume, stop, evaluate }

/// The autopilot as the tab shows it: from this machine's engine, or from the
/// linked host's last answer. [status] is null while neither has answered.
@immutable
class _AutopilotView {
  const _AutopilotView({
    required SchedulerStatus this.status,
    required this.decision,
    required SchedulerConfig this.config,
    required SchedulerStartReadiness this.readiness,
  })  : error = null,
        retry = null;

  const _AutopilotView.unavailable({this.error, this.retry})
      : status = null,
        decision = null,
        config = null,
        readiness = null;

  final SchedulerStatus? status;
  final SchedulerDecision? decision;
  final SchedulerConfig? config;
  final SchedulerStartReadiness? readiness;
  final Object? error;
  final VoidCallback? retry;

  bool get hasCandidates => decision?.scoredCandidates.isNotEmpty ?? false;
}

/// The autopilot in one row: its state, what it does next, why, and the
/// tab's one primary button.
class _AutopilotBar extends StatelessWidget {
  const _AutopilotBar({
    required this.view,
    required this.groupName,
    required this.busy,
    required this.compact,
    required this.nextLine,
    required this.onStart,
    required this.onAction,
    required this.onWhy,
    required this.onSettings,
  });

  final _AutopilotView view;
  final String? groupName;
  final bool busy;
  final bool compact;
  final String nextLine;
  final VoidCallback onStart;
  final ValueChanged<_AutopilotAction> onAction;
  final VoidCallback onWhy;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final status = view.status;
    final state = status?.state;

    final (chipLabel, chipTone) = switch (state) {
      null => ('—', ChipTone.neutral),
      SchedulerState.idle => ('Idle', ChipTone.neutral),
      SchedulerState.running => ('Running', ChipTone.success),
      SchedulerState.paused => ('Paused', ChipTone.warning),
    };
    final title = Text(
      groupName == null ? 'Autopilot' : 'Autopilot · $groupName',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: SkotiqTypography.sectionTitle.copyWith(color: colors.textPrimary),
    );
    final chip = SkotiqChip(
      key: const ValueKey('autopilot-state-chip'),
      label: chipLabel,
      tone: chipTone,
      dot: true,
    );
    final next = _NextLine(
      text: nextLine,
      nextCheckAt:
          state == SchedulerState.running ? status?.nextEvaluationAt : null,
    );

    final canStart =
        view.hasCandidates && !(view.readiness?.blocked ?? true) && !busy;
    final buttonSize = compact ? ButtonSize.medium : ButtonSize.small;
    final primary = switch (state) {
      null => view.retry == null
          ? null
          : SkotiqButton(
              label: 'Retry',
              size: buttonSize,
              variant: ButtonVariant.secondary,
              onPressed: view.retry,
            ),
      SchedulerState.idle => SkotiqTooltip(
          message: canStart
              ? 'Hands the night to the autopilot. It picks the best target '
                  'and picks again as the sky changes.'
              : view.hasCandidates
                  ? 'The rig is not ready yet.'
                  : 'There is no target it could image.',
          child: SkotiqButton(
            key: const ValueKey('autopilot-start'),
            label: 'Run unattended',
            icon: LucideIcons.play,
            size: buttonSize,
            isLoading: busy,
            onPressed: canStart ? onStart : null,
          ),
        ),
      SchedulerState.running => SkotiqButton(
          key: const ValueKey('autopilot-pause'),
          label: 'Pause',
          icon: LucideIcons.pause,
          size: buttonSize,
          onPressed: busy ? null : () => onAction(_AutopilotAction.pause),
        ),
      SchedulerState.paused => SkotiqButton(
          key: const ValueKey('autopilot-resume'),
          label: 'Resume',
          icon: LucideIcons.play,
          size: buttonSize,
          onPressed: busy ? null : () => onAction(_AutopilotAction.resume),
        ),
    };
    final stop = state == null || state == SchedulerState.idle
        ? null
        : SkotiqButton(
            key: const ValueKey('autopilot-stop'),
            label: 'Stop',
            size: buttonSize,
            variant: ButtonVariant.ghost,
            onPressed: busy ? null : () => onAction(_AutopilotAction.stop),
          );
    final why = SkotiqButton(
      key: const ValueKey('autopilot-why'),
      label: 'Why',
      size: buttonSize,
      variant: ButtonVariant.ghost,
      onPressed: status == null ? null : onWhy,
    );
    final rescore = SkotiqIconButton(
      key: const ValueKey('autopilot-rescore'),
      icon: LucideIcons.refreshCw,
      tooltip: 'Score the targets again now',
      size: compact ? IconButtonSize.md : IconButtonSize.sm,
      onPressed: status == null || busy
          ? null
          : () => onAction(_AutopilotAction.evaluate),
    );
    final settings = SkotiqIconButton(
      key: const ValueKey('autopilot-settings'),
      icon: LucideIcons.settings2,
      tooltip: 'Autopilot settings',
      size: compact ? IconButtonSize.md : IconButtonSize.sm,
      onPressed: view.config == null ? null : onSettings,
    );

    if (compact) {
      return SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(child: title),
                const SizedBox(width: SkotiqTokens.spaceSm),
                chip,
                const Spacer(),
                rescore,
                settings,
              ],
            ),
            next,
            const SizedBox(height: SkotiqTokens.spaceSm),
            Row(
              children: [
                if (primary != null) primary,
                if (stop != null) stop,
                const Spacer(),
                why,
              ],
            ),
          ],
        ),
      );
    }

    return SkotiqPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: [
          title,
          const SizedBox(width: SkotiqTokens.spaceMd),
          chip,
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(child: next),
          const SizedBox(width: SkotiqTokens.spaceSm),
          why,
          rescore,
          settings,
          if (stop != null) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            stop,
          ],
          if (primary != null) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            primary,
          ],
        ],
      ),
    );
  }
}

/// What the autopilot does next, with the time to its next check while it
/// runs. Only this line repaints each second.
class _NextLine extends StatefulWidget {
  const _NextLine({required this.text, required this.nextCheckAt});

  final String text;
  final DateTime? nextCheckAt;

  @override
  State<_NextLine> createState() => _NextLineState();
}

class _NextLineState extends State<_NextLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_NextLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.nextCheckAt == null) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final next = widget.nextCheckAt;
    var text = widget.text;
    if (next != null) {
      final left = next.difference(DateTime.now());
      text += left.isNegative
          ? ' · choosing now'
          : ' · next check in '
              '${DurationFormat.of(left, style: DurationStyle.short)}';
    }
    return Text(
      text,
      key: const ValueKey('autopilot-next-line'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
    );
  }
}
