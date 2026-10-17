import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Live status of the science processing pipeline.
///
/// Three states:
///   * **Idle**: no work in flight, no recent failures → shown as a subtle
///     "Science idle — N frames processed" line.
///   * **Busy**: a frame is being processed, or one is queued → animated
///     progress dot + the stage currently running.
///   * **Failure**: the most recent attempt produced at least one failed
///     stage → red accent with the stage name and the truncated note.
///
/// This widget is intentionally compact (1–2 lines tall) so it can sit at the
/// top of the Analytics Science tab and on the Imaging HUD without crowding
/// the rest of the layout.
class ScienceStatusBanner extends ConsumerWidget {
  /// When `true`, hides the banner entirely if the snapshot is empty (no
  /// inflight work, no history, no failure). Useful on the Imaging HUD where
  /// chrome budget is tight.
  final bool hideWhenIdle;

  /// Frames already on record for the session the surrounding surface is
  /// reporting on.
  ///
  /// Every other state on this banner comes from the in-memory pipeline
  /// tracker, which starts empty on every app launch; this count is what lets
  /// the banner tell idle apart from reviewing stored results.
  final int? storedFrameCount;

  const ScienceStatusBanner({
    super.key,
    this.hideWhenIdle = false,
    this.storedFrameCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final statusAsync = ref.watch(scienceProcessingStatusProvider);
    final error = statusAsync.error;

    if (statusAsync.hasError && error != null) {
      final style = _BannerStyle.error(colors);
      return _StatusContainer(
        style: style,
        colors: colors,
        icon: LucideIcons.alertTriangle,
        headline: 'Science status unavailable',
        subtitle: error.toString(),
        trailing: TextButton(
          onPressed: () => ref.invalidate(scienceProcessingStatusProvider),
          child: const Text('Retry'),
        ),
      );
    }

    final snapshot = statusAsync.valueOrNull;

    if (snapshot == null) {
      final style = _BannerStyle.busy(colors);
      return _StatusContainer(
        style: style,
        colors: colors,
        leading: SizedBox(
          width: 14,
          height: 14,
          child: SkotiqSpinner(size: 14, color: style.accent),
        ),
        headline: 'Loading science status…',
      );
    }

    final inflight = snapshot.inflight;
    final lastFailure = snapshot.lastFailure;
    final hasHistory = snapshot.history.isNotEmpty;
    final persistedFrameCount = storedFrameCount;

    if (hideWhenIdle &&
        inflight == null &&
        snapshot.queueDepth == 0 &&
        lastFailure == null &&
        !hasHistory) {
      return const SizedBox.shrink();
    }

    final _BannerStyle style;
    final String headline;
    String? subtitle;
    final IconData icon;
    Widget? leadingProgress;

    if (inflight != null) {
      style = _BannerStyle.busy(colors);
      final running = inflight.runningStages.toList();
      final running0 = running.isEmpty ? null : running.first;
      headline =
          running0 == null ? 'Processing frame…' : '${running0.displayName}…';
      subtitle = snapshot.queueDepth > 0
          ? '${snapshot.queueDepth} more queued'
          : 'Just this frame in flight';
      icon = LucideIcons.activity;
      leadingProgress = SizedBox(
        width: 14,
        height: 14,
        child: SkotiqSpinner(size: 14, color: style.accent),
      );
    } else if (lastFailure != null && _isRecent(lastFailure.timestamp)) {
      style = _BannerStyle.error(colors);
      headline = '${lastFailure.stage.displayName} failed';
      subtitle = lastFailure.note;
      icon = LucideIcons.alertTriangle;
    } else if (hasHistory) {
      final last = snapshot.history.first;
      style = _BannerStyle.idle(colors);
      headline = last.hasFailure
          ? 'Last frame finished with warnings'
          : 'Science up to date';
      final completedAt = last.finishedAt ?? last.startedAt;
      subtitle =
          '${snapshot.processedCount} frame${snapshot.processedCount == 1 ? '' : 's'} processed · last ${_relativeTime(completedAt)}';
      icon =
          last.hasFailure ? LucideIcons.alertCircle : LucideIcons.checkCircle;
    } else if (persistedFrameCount != null && persistedFrameCount > 0) {
      final frames = persistedFrameCount;
      style = _BannerStyle.idle(colors);
      headline = 'Reviewing stored results';
      subtitle = '$frames frame${frames == 1 ? '' : 's'} on record · '
          'nothing processing right now';
      icon = LucideIcons.history;
    } else {
      style = _BannerStyle.idle(colors);
      headline = 'Science idle';
      subtitle = 'Waiting for the first captured frame';
      icon = LucideIcons.flaskConical;
    }

    return _StatusContainer(
      style: style,
      colors: colors,
      icon: icon,
      leading: leadingProgress,
      headline: headline,
      subtitle: subtitle,
      trailing: inflight != null && inflight.stages.isNotEmpty
          ? _StageTicker(
              statuses: inflight.stages.values.toList(growable: false),
              colors: colors,
            )
          : null,
    );
  }

  bool _isRecent(DateTime ts) =>
      DateTime.now().difference(ts) < const Duration(minutes: 10);

  String _relativeTime(DateTime ts) {
    final delta = DateTime.now().difference(ts);
    if (delta.inSeconds < 30) return 'just now';
    if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return '${delta.inDays}d ago';
  }
}

class _StatusContainer extends StatelessWidget {
  const _StatusContainer({
    required this.style,
    required this.colors,
    required this.headline,
    this.icon,
    this.leading,
    this.subtitle,
    this.trailing,
  }) : assert(icon != null || leading != null);

  final _BannerStyle style;
  final SkotiqColors colors;
  final String headline;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitleText = subtitle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        children: [
          if (leading != null)
            leading!
          else
            Icon(icon!, size: 16, color: style.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  style: SkotiqTypography.caption.copyWith(
                      color: style.accent, fontWeight: FontWeight.w600),
                ),
                if (subtitleText != null && subtitleText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitleText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textSecondary, height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _StageTicker extends StatelessWidget {
  final List<ScienceStageResult> statuses;
  final SkotiqColors colors;

  const _StageTicker({required this.statuses, required this.colors});

  @override
  Widget build(BuildContext context) {
    final dots = <Widget>[];
    for (final stage in ScienceStage.values) {
      final match =
          statuses.where((r) => r.stage == stage).toList(growable: false);
      if (match.isEmpty) continue;
      final result = match.last;
      dots.add(
        Tooltip(
          message: _tooltipFor(result),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _colorFor(result, colors),
              ),
            ),
          ),
        ),
      );
    }
    if (dots.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: dots,
    );
  }

  String _tooltipFor(ScienceStageResult r) {
    final outcome = switch (r.outcome) {
      ScienceStageOutcome.running => 'running',
      ScienceStageOutcome.ok => 'ok',
      ScienceStageOutcome.skipped => 'skipped',
      ScienceStageOutcome.noData => 'no data',
      ScienceStageOutcome.failed => 'failed',
    };
    final note = r.note;
    return note == null || note.isEmpty
        ? '${r.stage.displayName} — $outcome'
        : '${r.stage.displayName} — $outcome\n$note';
  }

  Color _colorFor(ScienceStageResult r, SkotiqColors c) {
    switch (r.outcome) {
      case ScienceStageOutcome.ok:
        return c.success;
      case ScienceStageOutcome.running:
        return c.primary;
      case ScienceStageOutcome.skipped:
        return c.border;
      case ScienceStageOutcome.noData:
        return c.textMuted;
      case ScienceStageOutcome.failed:
        return c.error;
    }
  }
}

/// The three tones this banner takes, as tokens rather than as a decoration
/// it takes apart.
///
/// It used to read its own colours back out of a [BoxDecoration] and cast
/// `decoration.border` to a `Border`. That was already fragile, and it broke
/// outright when the deprecated `emphasisSurface` collapsed into
/// `SkotiqDecorations.chip`, which has no border at all -- because in this
/// language a tinted fill IS its own boundary (02 rule 2: tone, not lines).
class _BannerStyle {
  final Color background;
  final Color accent;

  const _BannerStyle({required this.background, required this.accent});

  /// A tone at the status-fill alpha, which is what every tinted status
  /// surface in the sheet is made of.
  factory _BannerStyle._ofTone(Color tone) => _BannerStyle(
        background: tone.withValues(alpha: SkotiqTokens.opacityStatusFill),
        accent: tone,
      );

  factory _BannerStyle.busy(SkotiqColors c) => _BannerStyle._ofTone(
        c.primary,
      );

  factory _BannerStyle.idle(SkotiqColors c) => _BannerStyle(
        background: c.well,
        accent: c.textSecondary,
      );

  factory _BannerStyle.error(SkotiqColors c) => _BannerStyle._ofTone(
        c.error,
      );
}
