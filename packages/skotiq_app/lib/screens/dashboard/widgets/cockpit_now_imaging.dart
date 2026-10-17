import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../sequencer/widgets/run_dashboard/run_dashboard_format.dart';
import '../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';

/// Merged "Now Imaging" cockpit strip — the active target header + exposure
/// progress condensed into a single compact full-width row.
///
/// Replaces the standalone `RunDashboardTargetHeader` and
/// `RunDashboardExposureProgress` panels, which were both tall and both about
/// "current run status." This strip keeps every essential readout — target
/// name + coordinates, altitude (color-coded), time-to-meridian, time-to-set,
/// the per-frame countdown with a thin inline bar, and the sequence
/// progress — while dropping the niche per-target integration-budget panel
/// (still available via the opt-in full target-header tile).
///
/// Reads the same providers as the originals:
/// [runDashboardActiveTargetProvider], [runDashboardSkyStatsProvider],
/// [exposureProgressProvider], [sequenceProgressProvider], and
/// [sequenceExecutionStateProvider]. Per-frame / sequence progress only render
/// while execution is active.
class CockpitNowImaging extends ConsumerWidget {
  const CockpitNowImaging({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final target = ref.watch(runDashboardActiveTargetProvider);
    // Glance mode is a DASHBOARD control, so the always-visible dashboard
    // readouts have to answer it. Before this only two run-scoped sequencer
    // panels opted in, and toggling the eye icon changed nothing on screen.
    final glance = ref.watch(glanceModeProvider);

    if (target == null) {
      // The instruction half must not contradict the rest of the screen: a
      // running sequence can legitimately have no TARGET NODE (free-form
      // capture), so telling the operator to "load a sequence" while the
      // toolbar offers Pause/Stop would be false.
      final executionState = ref.watch(sequenceExecutionStateProvider);
      final sequenceActive = executionState != SequenceExecutionState.idle &&
          executionState != SequenceExecutionState.completed &&
          executionState != SequenceExecutionState.failed;
      return _Shell(
        colors: colors,
        child: Row(
          children: [
            Icon(LucideIcons.target, size: 15, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                sequenceActive
                    ? 'No target set — sequence running without a target node.'
                    : 'No active target — load a sequence to begin.',
                style: SkotiqTypography.glanceStyle(
                  SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                  enabled: glance,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    final sky = ref.watch(runDashboardSkyStatsProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    // A settings read still in flight is not evidence the site is unset. Only
    // send the operator to go set one once the settings actually say it is
    // missing; until then the altitude is merely unknown.
    final locationUnset =
        settingsAsync.valueOrNull?.hasObserverLocation == false;

    final altText = sky != null
        ? '${sky.altitudeDeg.toStringAsFixed(1)}°'
        : (locationUnset ? 'set location' : '—');
    final altColor =
        sky == null ? colors.textMuted : _altitudeColor(sky, colors);

    final setLabel = sky == null
        ? 'To set'
        : sky.horizonDeg <= 0.01
            ? 'To set'
            : 'To ${sky.horizonDeg.toStringAsFixed(0)}°';

    final identity = _Identity(colors: colors, target: target, glance: glance);

    final chips = <Widget>[
      _StatChip(
        colors: colors,
        icon: LucideIcons.mountain,
        label: 'Altitude',
        value: altText,
        valueColor: altColor,
        glance: glance,
      ),
      _StatChip(
        colors: colors,
        icon: LucideIcons.timer,
        label: 'To meridian',
        value: formatDuration(sky?.timeToTransit),
        glance: glance,
      ),
      _StatChip(
        colors: colors,
        icon: LucideIcons.sunset,
        label: setLabel,
        value: formatDuration(sky?.timeToSet),
        glance: glance,
      ),
      _FrameChip(colors: colors, glance: glance),
      _SequenceChip(colors: colors, glance: glance),
    ];

    return _Shell(
      colors: colors,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: SkotiqTokens.spaceLg,
        runSpacing: SkotiqTokens.spaceSm,
        children: [
          identity,
          ...chips,
        ],
      ),
    );
  }
}

/// Grade the target's altitude against the *effective horizon* the rest of
/// the dashboard uses (`sky.horizonDeg`) instead of a hardcoded 30°. Below the
/// horizon the target is unobservable (error); within a margin above it the
/// target is low and degrading (warning); comfortably above it is good. The
/// 15° margin is clamped so a high obstruction horizon (e.g. 40°) still leaves
/// a sensible "low" band rather than collapsing warning/success together.
Color _altitudeColor(RunDashboardSkyStats sky, SkotiqColors colors) {
  final horizon = sky.horizonDeg;
  if (sky.altitudeDeg <= horizon) return colors.error;
  final margin =
      (90.0 - horizon) * 0.25 < 15.0 ? (90.0 - horizon) * 0.25 : 15.0;
  if (sky.altitudeDeg < horizon + margin) return colors.warning;
  return colors.success;
}

class _Identity extends StatelessWidget {
  final SkotiqColors colors;
  final TargetHeaderNode target;
  final bool glance;

  const _Identity({
    required this.colors,
    required this.target,
    required this.glance,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            target.displayName,
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.compass, size: 11, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              '${formatRA(target.raHours)}  ${formatDec(target.decDegrees)}',
              style: SkotiqTypography.withTabular(
                SkotiqTypography.glanceStyle(
                  SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
                  enabled: glance,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Compact label-over-value stat (altitude / to-meridian / to-set).
class _StatChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool glance;

  const _StatChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    required this.glance,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              label,
              style: SkotiqTypography.glanceStyle(
                SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
                enabled: glance,
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.sectionTitle
                .copyWith(color: valueColor ?? colors.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// This-frame countdown (mm:ss) with a thin inline progress bar. Hidden when no
/// exposure is in flight.
class _FrameChip extends ConsumerWidget {
  final SkotiqColors colors;
  final bool glance;

  const _FrameChip({required this.colors, required this.glance});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final isActive = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused ||
        executionState == SequenceExecutionState.stopping;
    if (!isActive) return const SizedBox.shrink();

    final exposure = ref.watch(exposureProgressProvider);
    final hasFrame = exposure.frameNumber > 0 && exposure.remaining > 0;
    if (!hasFrame && !exposure.isDownloading) return const SizedBox.shrink();

    final exposurePct = exposure.percent.clamp(0.0, 100.0) / 100.0;
    final valueText =
        hasFrame ? formatSeconds(exposure.remaining) : 'Downloading…';
    final valueColor = hasFrame ? colors.primary : colors.warning;

    return SizedBox(
      // The caption is what grows in glance mode, so the box has to grow with
      // it or 'This frame' clips at 14px.
      width: glance ? 120 : 88,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.timer, size: 10, color: colors.textMuted),
              const SizedBox(width: 4),
              Text(
                'This frame',
                style: SkotiqTypography.glanceStyle(
                  SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
                  enabled: glance,
                ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          Text(
            valueText,
            style: SkotiqTypography.withTabular(
              SkotiqTypography.sectionTitle.copyWith(color: valueColor),
            ),
          ),
          const SizedBox(height: 3),
          SkotiqProgressBar(
            value: hasFrame ? exposurePct : 0,
            height: 3,
          ),
        ],
      ),
    );
  }
}

/// Sequence progress: X/Y · % · ~ETA. Hidden when execution is not active.
class _SequenceChip extends ConsumerWidget {
  final SkotiqColors colors;
  final bool glance;

  const _SequenceChip({required this.colors, required this.glance});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final isActive = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused ||
        executionState == SequenceExecutionState.stopping;
    if (!isActive) return const SizedBox.shrink();

    final seq = ref.watch(sequenceProgressProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.listOrdered, size: 10, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              'Sequence',
              style: SkotiqTypography.glanceStyle(
                SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
                enabled: glance,
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${seq.completedExposures}/${seq.totalExposures}',
              style: SkotiqTypography.withTabular(
                SkotiqTypography.sectionTitle
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${(seq.progressPercent * 100).toStringAsFixed(0)}%',
              style: SkotiqTypography.withTabular(
                SkotiqTypography.glanceStyle(
                  SkotiqTypography.labelStrongSm.copyWith(
                    color: colors.primary,
                  ),
                  enabled: glance,
                ),
              ),
            ),
            if (seq.estimatedRemainingSecs != null) ...[
              const SizedBox(width: 6),
              Text(
                '~${formatSeconds(seq.estimatedRemainingSecs!)}',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.glanceStyle(
                    SkotiqTypography.caption.copyWith(color: colors.textMuted),
                    enabled: glance,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Self-chromed container matching the cockpit card styling, sized to a single
/// compact row.
class _Shell extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  const _Shell({required this.colors, required this.child});

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceMd,
        ),
        child: child);
  }
}
