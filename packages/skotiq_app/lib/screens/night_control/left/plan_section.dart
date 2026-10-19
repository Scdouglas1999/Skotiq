// The Plan block: integration against the plan's estimate, the end time, and
// one row per filter with its frames and captured time.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../data/plan/plan_progress_provider.dart';
import '../night_control_contracts.dart';
import 'left_section_frame.dart';
import 'night_time_format.dart';

class NightPlanSection extends ConsumerWidget {
  const NightPlanSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final plan = ref.watch(nightPlanProgressProvider);
    final live = ref.watch(nightRunPhaseProvider).isRunLive;
    final title = l10n.text('nightCtlPlanTitle');
    if (plan == null) {
      return NightLeftSectionFrame(
        title: title,
        gap: 5,
        child: NightLeftEmpty(l10n.text('nightCtlNoPlan')),
      );
    }
    final summary = _summary(l10n, plan, live: live);
    return NightLeftSectionFrame(
      title: title,
      gap: 5,
      trailing: Text(
        summary,
        style: NightLeftSectionFrame.noteStyle(colors),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
      ),
      child: plan.rows.isEmpty
          ? NightLeftEmpty(l10n.text('nightCtlPlanNoFrames'))
          : _FilterTable(rows: plan.rows, started: live || _anyCaptured(plan)),
    );
  }

  static bool _anyCaptured(NightPlanVm plan) =>
      plan.rows.any((r) => r.framesDone > 0);

  /// "5 h 10 m / ≈7 h · ETA ≈05:30" during a run, "0 / ≈7 h · ends ≈05:30"
  /// before one.
  static String _summary(
    SkotiqLocalizations l10n,
    NightPlanVm plan, {
    required bool live,
  }) {
    final integrated = plan.integrated == Duration.zero
        ? '0'
        : nightSpan(l10n, plan.integrated);
    final planned = plan.planned;
    final parts = <String>[
      planned == null
          ? integrated
          : '$integrated / $kNightEstimatePrefix${nightSpan(l10n, planned)}',
      if (plan.eta case final eta?)
        l10n.text(live ? 'nightCtlPlanEta' : 'nightCtlPlanEnds', params: {
          'time': nightHmMaybeEstimated(eta, estimated: true),
        }),
    ];
    return parts.join(' · ');
  }
}

/// Filter | progress bar | frames | captured time.
class _FilterTable extends StatelessWidget {
  const _FilterTable({required this.rows, required this.started});

  final List<PlanFilterRowVm> rows;

  /// Before anything is captured the time column reads "—", as on the
  /// Ready board.
  final bool started;

  static const double _barHeight = 5;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final scaler = MediaQuery.textScalerOf(context);
    const mono = SkotiqTypography.monoXs;
    final labelStyle = SkotiqTypography.labelStrongSm.copyWith(fontSize: 12);
    // The filter column fits the longest name up to a cap, so a long name
    // ellipsizes instead of eating the bar, and every bar starts at one x.
    var labelWidth = scaler.scale(22);
    for (final r in rows) {
      final w = measureTextWidth(context, text: r.filter, style: labelStyle);
      if (w > labelWidth) labelWidth = w;
    }
    labelWidth = labelWidth.clamp(0, scaler.scale(56)).toDouble();

    Widget row(PlanFilterRowVm r) {
      final fraction = r.fraction;
      final count = r.framesPlanned == null
          ? '${r.framesDone}'
          : '${r.framesDone}/${r.framesPlanned}';
      final time =
          !started && r.framesDone == 0 ? '—' : nightFilterTime(r.integrated);
      final labelColor = r.isCurrent
          ? colors.textPrimary
          : started
              ? colors.textMuted
              : colors.textSecondary;
      return Semantics(
        container: true,
        label: _rowSentence(l10n, r),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    r.filter,
                    style: labelStyle.copyWith(color: labelColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                const SizedBox(width: _gap),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_barHeight / 2),
                    child: SizedBox(
                      height: _barHeight,
                      // An open-ended step has no fraction: an empty track.
                      child: ColoredBox(
                        color: colors.surfaceHover,
                        child: fraction == null
                            ? const SizedBox.expand()
                            : FractionallySizedBox(
                                alignment: AlignmentDirectional.centerStart,
                                widthFactor: fraction,
                                child: ColoredBox(
                                  color: r.isCurrent
                                      ? colors.primary
                                      : colors.accent,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: scaler.scale(48),
                  child: Text(
                    count,
                    textAlign: TextAlign.right,
                    style: mono.copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: scaler.scale(44),
                  child: Text(
                    time,
                    textAlign: TextAlign.right,
                    style: mono.copyWith(color: colors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[for (final r in rows) row(r)],
    );
  }

  /// "Ha: 43 of 60 frames, 2 h 09 m captured, exposing now".
  String _rowSentence(SkotiqLocalizations l10n, PlanFilterRowVm r) {
    final planned = r.framesPlanned;
    final base = planned == null
        ? l10n.text('nightCtlPlanRowSemOpen', params: {
            'filter': r.filter,
            'done': '${r.framesDone}',
            'time': nightSpan(l10n, r.integrated),
          })
        : l10n.text('nightCtlPlanRowSem', params: {
            'filter': r.filter,
            'done': '${r.framesDone}',
            'planned': '$planned',
            'time': nightSpan(l10n, r.integrated),
          });
    return r.isCurrent ? '$base, ${l10n.text('nightCtlPlanRowCurrent')}' : base;
  }
}
