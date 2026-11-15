import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../utils/count_label.dart';
import '../../../../widgets/run_status/run_status_presentation.dart';
import '../../analytics_providers.dart';
import '../../widgets/session_chart_grid.dart';
import '../night_entry.dart';

/// The Summary of a night: what was captured and kept, how the run spent its
/// time, why it ended if it ended badly, and the charts of its frames.
class NightSummaryView extends ConsumerWidget {
  const NightSummaryView({
    super.key,
    required this.entry,
    required this.targetName,
    required this.padding,
    required this.compact,
  });

  final NightEntry entry;
  final String? targetName;
  final EdgeInsets padding;

  /// Phone width: panels and charts stack.
  final bool compact;

  static const double _gap = SkotiqTokens.spaceLg;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = entry.session;
    final stats = entry.stats;
    final framesAsync =
        session == null ? null : ref.watch(dbSessionImagesProvider(session.id));
    final ending = entry.ending;
    // A stop the operator asked for is not a problem the run reported.
    final problems = stats == null
        ? const <String>[]
        : runErrorMessagesFor(ending, stats.errorMessages);
    final cause = stats == null
        ? null
        : runFailureHeadline(
            terminalCause: stats.terminalCause,
            errors: problems,
          );
    final endedBadly = ending == SequenceRunStatus.failed ||
        ending == SequenceRunStatus.aborted;
    final target = targetName ?? entry.runTargets.firstOrNull;

    return SingleChildScrollView(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (cause != null) ...[
            SkotiqBanner(
              tone: endedBadly ? BannerTone.error : BannerTone.warning,
              title: endedBadly ? 'Why the run ended' : 'Reported by the run',
              message: runFailureMessage(cause),
            ),
            const SizedBox(height: _gap),
          ],
          _NightPanel(entry: entry, frames: framesAsync?.valueOrNull),
          if (target != null) _TargetTotal(targetName: target),
          if (stats != null) ...[
            const SizedBox(height: _gap),
            _RunPanel(stats: stats),
            if (stats.targetBreakdown.isNotEmpty) ...[
              const SizedBox(height: _gap),
              _TargetsPanel(stats: stats),
            ],
            if (problems.length > 1) ...[
              const SizedBox(height: _gap),
              _ProblemsPanel(problems: problems),
            ],
          ],
          if (framesAsync != null) ...[
            const SizedBox(height: _gap),
            framesAsync.when(
              data: (frames) =>
                  SessionChartGrid(frames: frames, stacked: compact),
              loading: () => const ShimmerLoading(
                child: SkotiqPanel(child: SizedBox(height: 240)),
              ),
              error: (error, _) => SkotiqBanner(
                tone: BannerTone.error,
                title: 'Frames did not load',
                message: userFacingError(error),
                action: SkotiqButton(
                  label: 'Retry',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () =>
                      ref.invalidate(dbSessionImagesProvider(session!.id)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The night's numbers. The capture count is the session's own; accepted and
/// rejected are counted from the frames, the one place the verdict is kept.
class _NightPanel extends StatelessWidget {
  const _NightPanel({required this.entry, required this.frames});

  final NightEntry entry;

  /// Null while the frames have not loaded, or for a run with no session.
  final List<DbCapturedImage>? frames;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = SkotiqColors.of(context);
    final session = entry.session;
    final stats = entry.stats;
    final lights = frames?.where((image) => image.isLight);
    final accepted = lights?.where((image) => image.isAccepted).length ??
        (session == null && stats != null
            ? stats.framesCaptured - stats.framesRejected
            : null);
    final rejected = lights?.where((image) => !image.isAccepted).length ??
        (session == null ? stats?.framesRejected : null);
    final exposures = session?.totalExposures ?? stats?.framesCaptured;
    final integration =
        session?.totalIntegrationSecs ?? stats?.integrationSecs;

    return SkotiqPanel(
      head: const PanelHead(label: 'Night', icon: SkotiqIcons.moon),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReadoutRow(
            children: [
              Readout(
                label: l10n.text('analyticsTotalExposures'),
                value: exposures?.toString(),
              ),
              Readout(
                label: l10n.text('analyticsAcceptedLights'),
                value: accepted?.toString(),
              ),
              Readout(
                label: l10n.text('analyticsRejectedLights'),
                value: rejected?.toString(),
                valueColor:
                    rejected != null && rejected > 0 ? colors.warning : null,
              ),
              Readout(
                label: l10n.text('analyticsIntegration'),
                value: integration != null && integration > 0
                    ? DurationFormat.decimalHours(integration)
                    : null,
              ),
              Readout(
                label: l10n.text('analyticsAvgHfr'),
                unit: 'px',
                value: session?.avgHfr?.toStringAsFixed(2),
              ),
              Readout(
                label: l10n.text('analyticsAvgRms'),
                // ASCII, not U+2033: the bundled fonts have no prime glyph.
                unit: '"',
                value: session?.avgGuidingRms?.toStringAsFixed(2),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            frames == null && session != null
                ? l10n.text('analyticsGradingUnread')
                : l10n.text('analyticsExposureCountsLightOnly'),
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// How much the target has across every night, when this is not its only one.
class _TargetTotal extends ConsumerWidget {
  const _TargetTotal({required this.targetName});

  final String targetName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rollup =
        ref.watch(campaignRollupByNameProvider(targetName)).valueOrNull;
    if (rollup == null || rollup.sessionCount <= 1) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(
        top: SkotiqTokens.spaceSm,
        left: SkotiqTokens.spaceLg,
      ),
      child: Text(
        '$targetName has '
        '${DurationFormat.decimalHours(rollup.totalCapturedIntegrationSecs)} '
        'over ${rollup.sessionCount} sessions.',
        style: SkotiqTypography.bodySm.copyWith(
          color: SkotiqColors.of(context).textSecondary,
        ),
      ),
    );
  }
}

/// How the run spent its time and what it did along the way.
class _RunPanel extends StatelessWidget {
  const _RunPanel({required this.stats});

  final ParsedRunStats stats;

  @override
  Widget build(BuildContext context) {
    Readout time(String label, double seconds) => Readout(
          size: ReadoutSize.sm,
          label: label,
          value: seconds > 0
              ? DurationFormat.seconds(seconds, style: DurationStyle.short)
              : null,
        );
    Readout count(String label, int value) =>
        Readout(size: ReadoutSize.sm, label: label, value: '$value');

    return SkotiqPanel(
      head: const PanelHead(label: 'Run', icon: SkotiqIcons.clock),
      child: ReadoutRow(
        children: [
          time('Wall clock', stats.wallClockSecs),
          time('Integration', stats.integrationSecs),
          time('Overhead', stats.overheadSecs),
          Readout(
            size: ReadoutSize.sm,
            label: 'Efficiency',
            value: stats.wallClockSecs > 0
                ? QuantityFormat.percent(
                    stats.integrationSecs / stats.wallClockSecs * 100,
                  )
                : null,
          ),
          count('Autofocus runs', stats.autofocusRuns),
          count('Meridian flips', stats.meridianFlips),
          count('Dithers', stats.ditherCount),
          count('Trigger fires', stats.triggerFires),
        ],
      ),
    );
  }
}

/// What the run captured for each target and filter.
class _TargetsPanel extends StatelessWidget {
  const _TargetsPanel({required this.stats});

  final ParsedRunStats stats;

  /// Keeps a filter's name and its figures within one glance of each other.
  static const double _listWidth = 360;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      head: const PanelHead(label: 'Targets', icon: SkotiqIcons.target),
      child: Wrap(
        spacing: SkotiqTokens.space3xl,
        runSpacing: SkotiqTokens.spaceLg,
        children: [
          for (final target in stats.targetBreakdown.entries)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _listWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    target.key,
                    style: SkotiqTypography.bodyStrong
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  KeyValueList(
                    rows: [
                      for (final filter in target.value.entries)
                        (
                          filter.key.isEmpty ? 'No filter' : filter.key,
                          [
                            if (filter.value['captured'] case final num n)
                              countLabel(n.toInt(), 'frame'),
                            if (filter.value['integrationSecs']
                                case final num secs)
                              DurationFormat.seconds(
                                secs.toDouble(),
                                style: DurationStyle.short,
                              ),
                          ].join(' · '),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Everything the run reported going wrong, in the order it happened.
class _ProblemsPanel extends StatelessWidget {
  const _ProblemsPanel({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      head: PanelHead(
        label: 'Problems · ${problems.length}',
        icon: SkotiqIcons.error,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, problem) in problems.indexed) ...[
            if (index > 0)
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
                child: Container(height: 1, color: colors.border),
              ),
            SelectableText(
              runFailureMessage(problem),
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
