// The Steps list: the plan flattened, with what is done, what runs now and
// when the rest is planned. A row, or "open in Sequencer", selects that node
// in the Sequencer and goes there.
//
// While the plan column scrolls itself, the running step is kept in view:
// when it changes, the column scrolls just enough to show it. In the single
// column the page scrolls, and yanking the page to the plan section would
// pull the frame away from the operator, so nothing moves there.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' show selectedNodeIdProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../sequencer/sequencer_screen.dart' show kSequencerRoutePath;
import '../data/plan/plan_steps_provider.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';
import 'left_section_frame.dart';
import 'night_time_format.dart';

class NightStepsSection extends ConsumerStatefulWidget {
  const NightStepsSection({super.key});

  /// How long the scroll to a newly active step takes.
  static const Duration revealDuration = Duration(milliseconds: 250);

  @override
  ConsumerState<NightStepsSection> createState() => _NightStepsSectionState();
}

class _NightStepsSectionState extends ConsumerState<NightStepsSection> {
  final GlobalKey _activeKey = GlobalKey(debugLabel: 'activeStep');

  /// The step last brought into view, so a rebuild with the same active
  /// step leaves a scroll the operator made alone.
  String? _revealed;

  void _scheduleReveal(String? activeId, bool scrollsItself) {
    if (activeId == null || !scrollsItself || activeId == _revealed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_reveal()) _revealed = activeId;
    });
  }

  /// Scrolls the nearest scrollable just enough to show the active row,
  /// centering it when it was out of view. True when the row was laid out.
  bool _reveal() {
    final context = _activeKey.currentContext;
    final box = context?.findRenderObject();
    if (context == null || box == null || !box.attached) return false;
    final scrollable = Scrollable.maybeOf(context);
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (scrollable == null || viewport == null) return true;
    final position = scrollable.position;
    final atTop = viewport.getOffsetToReveal(box, 0).offset;
    final atBottom = viewport.getOffsetToReveal(box, 1).offset;
    if (position.pixels >= atBottom && position.pixels <= atTop) return true;
    final target = viewport
        .getOffsetToReveal(box, 0.5)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      position.jumpTo(target);
    } else {
      position.animateTo(
        target,
        duration: NightStepsSection.revealDuration,
        curve: Curves.easeOutCubic,
      );
    }
    return true;
  }

  void _open(String nodeId) {
    ref.read(selectedNodeIdProvider.notifier).state = nodeId;
    NightControlDensity.maybeOf(context)?.closePlanDrawer?.call();
    context.go(kSequencerRoutePath);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final steps = ref.watch(nightPlanStepsProvider);
    final scrollsItself =
        NightControlDensity.maybeOf(context)?.slotsScrollThemselves ?? true;
    final active =
        steps.where((s) => s.status == PlanStepStatus.active).firstOrNull;
    _scheduleReveal(active?.nodeId, scrollsItself);

    final openId = active?.nodeId ?? steps.firstOrNull?.nodeId;
    return NightLeftSectionFrame(
      title: l10n.text('nightCtlStepsTitle'),
      gap: 5,
      trailing: openId == null
          ? null
          : _OpenLink(
              label: l10n.text('nightCtlOpenInSequencer'),
              onTap: () => _open(openId),
            ),
      child: steps.isEmpty
          ? NightLeftEmpty(l10n.text('nightCtlStepsEmpty'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final step in steps)
                  _StepRow(
                    key: identical(step, active) ? _activeKey : null,
                    step: step,
                    colors: colors,
                    onTap: () => _open(step.nodeId),
                  ),
              ],
            ),
    );
  }
}

class _OpenLink extends StatelessWidget {
  const _OpenLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      button: true,
      link: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: SkotiqTokens.borderRadiusXs,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Text(
            label,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    super.key,
    required this.step,
    required this.colors,
    required this.onTap,
  });

  final PlanStepVm step;
  final SkotiqColors colors;
  final VoidCallback onTap;

  static const double _markSize = 12;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final active = step.status == PlanStepStatus.active;
    final ink = switch (step.status) {
      PlanStepStatus.active => colors.textPrimary,
      PlanStepStatus.pending => colors.textSecondary,
      PlanStepStatus.failed => colors.error,
      PlanStepStatus.done || PlanStepStatus.skipped => colors.textMuted,
    };
    final (icon, iconColor) = switch (step.status) {
      PlanStepStatus.done => (LucideIcons.check, colors.textMuted),
      PlanStepStatus.active => (LucideIcons.play, colors.primary),
      PlanStepStatus.pending => (LucideIcons.dot, colors.textSecondary),
      PlanStepStatus.failed => (LucideIcons.x, colors.error),
      PlanStepStatus.skipped => (LucideIcons.skipForward, colors.textMuted),
    };
    final when = _when(step.when);
    final statusText = l10n.text(switch (step.status) {
      PlanStepStatus.done => 'nightCtlStepDone',
      PlanStepStatus.active => 'nightCtlStepActive',
      PlanStepStatus.pending => 'nightCtlStepPending',
      PlanStepStatus.failed => 'nightCtlStepFailed',
      PlanStepStatus.skipped => 'nightCtlStepSkipped',
    });
    final indent = (step.depth.clamp(0, 4) * 6).toDouble();

    return Semantics(
      button: true,
      selected: active,
      label: [step.label, statusText, if (when != null) when].join(', '),
      hint: l10n.text('nightCtlStepOpenHint'),
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: SkotiqTokens.borderRadiusSm,
          child: Ink(
            decoration: BoxDecoration(
              color: active ? colors.primary.withValues(alpha: 0.16) : null,
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
            padding: EdgeInsetsDirectional.fromSTEB(6 + indent, 3, 6, 3),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 14,
                  child: Icon(icon, size: _markSize, color: iconColor),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    step.label,
                    style: SkotiqTypography.caption.copyWith(
                      color: ink,
                      fontWeight: active ? FontWeight.w600 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                if (when != null) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    when,
                    style: SkotiqTypography.monoXs.copyWith(
                      color: colors.textMuted,
                    ),
                    maxLines: 1,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "19:52" recorded, "≈03:40" planned, "44/60" running.
  static String? _when(StepWhen? when) => switch (when) {
        null => null,
        StepWhenActual(:final at) => nightHm(at),
        StepWhenPlanned(:final at) =>
          nightHmMaybeEstimated(at, estimated: true),
        StepWhenProgress(:final done, :final total) =>
          total == null ? '$done' : '$done/$total',
      };
}
