part of '../session_report_dialog.dart';

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _StatChip({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      variant: CardVariant.subtle,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      borderRadius: SkotiqTokens.radiusMd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10, color: colors.textMuted),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: SkotiqTypography.labelStrong
                .copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// Recovery Mode — single-row tile rendering a completed recovery
/// loop in the post-session report. Shows cause, attempt count, duration,
/// outcome (recovered / exhausted / aborted) and the final error message
/// (truncated).
class _RecoveryHistoryTile extends StatelessWidget {
  final RecoveryHistoryEntry entry;
  final SkotiqColors colors;

  const _RecoveryHistoryTile({required this.entry, required this.colors});

  @override
  Widget build(BuildContext context) {
    final outcomeColor = entry.recovered
        ? colors.success
        : (entry.abortedByUser ? colors.warning : colors.error);
    final outcomeLabel = entry.recovered
        ? 'recovered'
        : (entry.abortedByUser ? 'aborted by operator' : 'exhausted');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.iconChip(
        outcomeColor,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        borderAlpha: 0.35,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.cause.displayLabel,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              Text(
                outcomeLabel,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  color: outcomeColor,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${entry.attempts} attempt${entry.attempts == 1 ? '' : 's'} · '
            '${_formatDuration(entry.durationSecs)}',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (entry.lastError != null && entry.lastError!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              entry.lastError!,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  String _formatDuration(double secs) {
    if (secs < 60) return '${secs.toStringAsFixed(0)}s';
    final mins = (secs / 60).floor();
    final rem = (secs - mins * 60).round();
    if (rem == 0) return '${mins}m';
    return '${mins}m ${rem}s';
  }
}

/// Render one post-session [SessionInsight] inside the
/// Suggestions section. Includes:
///   * Title + confidence badge.
///   * Optional body / recommendation (collapsed by default; tap to
///     expand — same affordance as the diagnostic tile).
///   * "Apply" button when the insight has an `applyHint` (e.g. an
///     `altitudeAboveDeg` value that pre-fills the target editor).
///   * "Dismiss" + "Don't suggest this again" (sticky via
///     [dismissedSessionInsightsProvider]).
class _SessionInsightTile extends ConsumerStatefulWidget {
  final SessionInsight insight;
  final SkotiqColors colors;

  const _SessionInsightTile({
    required this.insight,
    required this.colors,
  });

  @override
  ConsumerState<_SessionInsightTile> createState() =>
      _SessionInsightTileState();
}

class _SessionInsightTileState extends ConsumerState<_SessionInsightTile> {
  bool _expanded = false;
  bool _dismissed = false;

  IconData _iconForKind(SessionInsightKind kind) {
    switch (kind) {
      case SessionInsightKind.altitudeWindow:
        return LucideIcons.arrowUpRight;
      case SessionInsightKind.autofocusFrequency:
        return LucideIcons.focus;
      case SessionInsightKind.filterChangeOverhead:
        return LucideIcons.filter;
      case SessionInsightKind.rejectionRate:
        return LucideIcons.xCircle;
      case SessionInsightKind.guidingDegraded:
        return LucideIcons.activity;
      case SessionInsightKind.efficiencyLow:
        return LucideIcons.timer;
      case SessionInsightKind.informational:
        return LucideIcons.info;
    }
  }

  Color _confidenceColor(double confidence, SkotiqColors c) {
    if (confidence >= 0.75) return c.error;
    if (confidence >= 0.5) return c.warning;
    return c.info;
  }

  /// Apply the insight's `applyHint` payload. Today we only support
  /// the `altitudeAboveDeg` hint (jump to the target editor with the
  /// suggested `startWhen` crossing). Future hint types would land
  /// in this switch.
  Future<void> _onApply() async {
    final hint = widget.insight.applyHint;
    if (hint == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (hint.containsKey('altitudeAboveDeg')) {
      final value = (hint['altitudeAboveDeg'] as num?)?.toDouble();
      if (value == null) return;
      // Pre-fill the editor by mutating the live in-editor sequence:
      // find the target by id (when supplied) and update its
      // startWhen. The editor is the active surface when the user
      // closes the report — so the change is visible immediately.
      final notifier = ref.read(currentSequenceProvider.notifier);
      final sequence = ref.read(currentSequenceProvider);
      if (sequence == null) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('No sequence is open to apply the suggestion to.'),
          ),
        );
        return;
      }
      final headers = sequence.targetHeaders;
      // The insight's target NAME (when the optimizer attached one via
      // applyHint) is the only reliable join key — the in-editor node tree does
      // not carry the Drift `targetId`. Falling back to the first header would
      // mutate the wrong target on a multi-target sequence.
      final hintTargetName = hint['targetName'] as String?;
      TargetHeaderNode? match;
      if (hintTargetName != null && hintTargetName.isNotEmpty) {
        for (final h in headers) {
          if (h.targetName == hintTargetName) {
            match = h;
            break;
          }
        }
      }
      // Only fall back to .first when the insight is target-agnostic AND
      // there is exactly one target — otherwise we can't safely guess
      // which target the suggestion was about.
      if (match == null &&
          (hintTargetName == null || hintTargetName.isEmpty) &&
          headers.length == 1) {
        match = headers.first;
      }
      if (match == null) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text(
              'Could not resolve which target to apply altitude to.',
            ),
          ),
        );
        return;
      }
      notifier.updateNode(match.copyWith(
        startWhen: AltitudeAboveTrigger(value),
      ));
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Applied: ${match.targetName} starts at '
            '${value.toStringAsFixed(0)}° altitude.',
          ),
        ),
      );
      return;
    }
    if (hint.containsKey('autofocusInterval')) {
      // No auto-mutation of global settings from a single insight click —
      // send the user to the Autofocus settings section to adjust the
      // cadence themselves. Close the report first so the settings screen
      // isn't left stranded beneath the dialog.
      final router = GoRouter.maybeOf(context);
      Navigator.of(context).pop();
      router?.go('/settings?section=autofocus');
      return;
    }
  }

  /// Label for the action button. Hints we can write straight into the
  /// editor read "Apply" (altitude); hints that only point at a settings
  /// screen read "Open Settings" so the button never overpromises.
  String get _actionLabel {
    final hint = widget.insight.applyHint;
    if (hint != null && hint.containsKey('autofocusInterval')) {
      return 'Open settings';
    }
    return 'Apply';
  }

  Future<void> _onDismiss({required bool sticky}) async {
    setState(() => _dismissed = true);
    if (!sticky) return;
    try {
      await ref
          .read(dismissedSessionInsightsProvider.notifier)
          .dismiss(widget.insight.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _dismissed = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Could not save dismissed suggestion: $error'),
          backgroundColor: widget.colors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final c = widget.colors;
    final conf = widget.insight.confidence;
    final confColor = _confidenceColor(conf, c);
    final hasBody =
        (widget.insight.body != null && widget.insight.body!.isNotEmpty) ||
            (widget.insight.recommendation != null &&
                widget.insight.recommendation!.isNotEmpty);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: confColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_iconForKind(widget.insight.kind),
                  size: 14, color: confColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.insight.title,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: SkotiqDecorations.statusChip(
                  confColor,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                  bordered: false,
                ),
                child: Text(
                  '${(conf * 100).round()}%',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    fontWeight: FontWeight.w700,
                    color: confColor,
                  ),
                ),
              ),
            ],
          ),
          if (hasBody) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Text(
                    _expanded ? 'Hide details' : 'Show details',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: c.textMuted,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  Icon(
                    _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 12,
                    color: c.textMuted,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              if (widget.insight.body != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.insight.body!,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: c.textSecondary,
                  ),
                ),
              ],
              if (widget.insight.recommendation != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.insight.recommendation!,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: c.primary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.insight.isActionable)
                TextButton(
                  onPressed: _onApply,
                  child: Text(
                    _actionLabel,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => _onDismiss(sticky: false),
                child: Text(
                  'Dismiss',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: c.textMuted),
                ),
              ),
              TextButton(
                onPressed: () => _onDismiss(sticky: true),
                child: Text(
                  "Don't suggest again",
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Single diagnostic line in the session report's
/// Diagnostics section. Mirrors the look of `_PreflightSection`'s
/// issue rows but with the lighter post-session tone (everything is
/// info-severity).
