// The progress panel — Tonight's c4 tile, row 2 (06 §Tonight).
//
// A 96 px ring with the run's percentage inside it, the per-filter bars beside
// it, and Integrated / Remaining / Rejected underneath.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../sequencer/widgets/run_dashboard/quality_panel.dart'
    show runDashboardQualitySummaryProvider;
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'tonight_hero.dart' show TonightHeroState, tonightHeroStateProvider;
import 'tonight_night.dart';

/// The ring's diameter and stroke (06 §Tonight, row 2).
const double _ringSize = 96;
const double _ringStroke = 7;

/// The per-filter bar grid: 28 for the filter letter, the track, 64 for the
/// count.
const double _filterLabelWidth = 28;
const double _filterCountWidth = 64;
const double _barTrackHeight = 6;

class TonightProgressPanel extends ConsumerWidget {
  const TonightProgressPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final progress = ref.watch(sequenceProgressProvider);
    final totals = ref.watch(runDashboardFilterTotalsProvider);
    final quality = ref.watch(runDashboardQualitySummaryProvider);

    final percent = (progress.progressPercent * 100).round();
    final remaining = progress.estimatedRemainingSecs;
    final endsAt = remaining == null
        ? null
        : DateTime.now().add(Duration(seconds: remaining.round()));

    // The plan's own filter order, NOT alphabetical: sorting put B before Lum
    // and R, which is not the order anyone builds or reads an LRGB run in.
    final filters = totals.goalSecs.keys.toList(growable: false);

    final head = PanelHead(
      icon: LucideIcons.activity,
      label: l10n.text('tnProgress'),
      trailing: <Widget>[
        if (endsAt != null)
          Text(
            l10n.text('tnEndsAt', params: {'time': tonightClock(endsAt)}),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
      ],
    );

    // Nothing to run and nothing run yet: a 0% ring, "No per-filter plan" and
    // a row of em dashes said the same absence three ways at full height.
    final nothingLoaded = ref.watch(tonightHeroStateProvider) ==
            TonightHeroState.nothingRunning &&
        progress.completedIntegrationSecs <= 0;
    if (nothingLoaded) {
      return SkotiqPanel(
        head: head,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                l10n.text('tnNothingLoaded'),
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            SkotiqButton(
              label: l10n.text('tnOpenSequencer'),
              icon: LucideIcons.listOrdered,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => context.go('/sequencer'),
            ),
          ],
        ),
      );
    }

    return SkotiqPanel(
      head: head,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _ProgressRing(percent: percent, colors: colors),
              const SizedBox(width: 18),
              Expanded(
                child: filters.isEmpty
                    ? Text(
                        l10n.text('tnNoFilterPlan'),
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textMuted,
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (final filter in filters)
                            _FilterBar(
                              filter: filter,
                              acquiredSecs: totals.integrationSecs[filter] ?? 0,
                              goalSecs: totals.goalSecs[filter] ?? 0,
                              colors: colors,
                            ),
                        ],
                      ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          ReadoutRow(
            gap: SkotiqTokens.space2xl,
            children: <Readout>[
              Readout(
                value: tonightDuration(
                  Duration(seconds: progress.completedIntegrationSecs.round()),
                ),
                label: l10n.text('tnIntegrated'),
              ),
              Readout(
                value: remaining == null
                    ? null
                    : tonightDuration(Duration(seconds: remaining.round())),
                label: l10n.text('tnRemaining'),
              ),
              Readout(
                value: quality.total == 0 ? null : '${quality.rejected}',
                unit: quality.total == 0 ? null : '/${quality.total}',
                label: l10n.text('tnRejected'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The 96 px ring: a `well` track under a `primary` arc, percentage inside.
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.percent, required this.colors});

  final int percent;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _ringSize,
      height: _ringSize,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          CustomPaint(
            size: const Size.square(_ringSize),
            painter: _RingPainter(
              fraction: (percent / 100).clamp(0.0, 1.0),
              colors: colors,
            ),
          ),
          // The percentage is a readout VALUE without a label — a [Readout]
          // would reserve its 11 px label row and push the number off the
          // ring's centre — so it is drawn from the same style with the same
          // 60% muted unit rule (03 §2).
          Text.rich(
            TextSpan(
              text: '$percent',
              children: <InlineSpan>[
                TextSpan(
                  text: '%',
                  style: SkotiqTypography.readoutMd.apply(
                    fontSizeFactor: Readout.unitScale,
                    fontWeightDelta: -1,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
            style: SkotiqTypography.readoutMd.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.fraction, required this.colors});

  final double fraction;
  final SkotiqColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = (size.width - _ringStroke) / 2;
    final rect = Rect.fromCircle(center: centre, radius: radius);

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke
        ..color = colors.well,
    );
    if (fraction <= 0) return;

    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke
        ..strokeCap = StrokeCap.round
        ..color = colors.primary,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.colors != colors;
}

/// `[L] [============-----] [28 / 40]`, in minutes of integration.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.acquiredSecs,
    required this.goalSecs,
    required this.colors,
  });

  final String filter;
  final double acquiredSecs;
  final double goalSecs;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final fraction =
        goalSecs <= 0 ? 0.0 : (acquiredSecs / goalSecs).clamp(0.0, 1.0);
    final acquiredMin = (acquiredSecs / 60).round();
    final goalMin = (goalSecs / 60).round();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _filterLabelWidth,
            child: Text(
              filter,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: SkotiqTokens.borderRadiusXs,
              child: SizedBox(
                height: _barTrackHeight,
                child: ColoredBox(
                  color: colors.well,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: ColoredBox(color: colors.primary),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _filterCountWidth,
            child: Text(
              '$acquiredMin / $goalMin',
              textAlign: TextAlign.right,
              style: SkotiqTypography.readoutXs.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
