import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../glass_card.dart';

/// Builds tonight's optimized target plan, guarded by a configured location.
///
/// This mirrors the provider pattern at the head of `tonight_card.dart` so the
/// briefing and the cockpit Tonight tile agree on the recommended plan. It is
/// kept private to the standby briefing; the cockpit tile owns its own copy.
final _briefingPlanProvider =
    FutureProvider.autoDispose<SessionOptimizationPlan>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  if (!settings.hasObserverLocation) {
    return SessionOptimizationPlan(
      generatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      primaryTarget: null,
      alternates: const [],
      recommendedExposureSeconds: 0,
      estimatedUsableHours: 0,
      rationale: const ['Set an observing location to generate target plans.'],
      riskFactors: const [],
    );
  }

  final suggestions = await ref.watch(tonightSuggestionsProvider.future);
  final exposureContext = suggestions.isEmpty
      ? null
      : await ref.watch(smartNightExposureContextProvider.future);
  final optimizer = SessionOptimizerService(
    suggestionService: ref.watch(targetSuggestionServiceProvider),
  );

  return optimizer.buildPlanFromSuggestions(
    suggestions,
    generatedAt: DateTime.now(),
    exposureContext: exposureContext,
  );
});

/// Tonight's recommended targets: the primary prominently, with up to three
/// compact alternates. Empty/no-location states explain themselves rather than
/// showing a blank card.
class TonightTargetsCard extends ConsumerWidget {
  final SkotiqColors colors;

  const TonightTargetsCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planAsync = ref.watch(_briefingPlanProvider);
    final plan = planAsync.valueOrNull;

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.target,
            title: context.l10n.text('dbTonightTargets'),
            accent: colors.primary,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          if (plan == null || !plan.hasRecommendation)
            _emptyBody(context, ref, planAsync)
          else
            _planBody(context, plan),
        ],
      ),
    );
  }

  Widget _emptyBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<SessionOptimizationPlan> planAsync,
  ) {
    if (planAsync.isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          context.l10n.text('dbTargetsPlanning'),
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textMuted,
          ),
        ),
      );
    }
    if (planAsync.hasError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.text('dbTargetsError'),
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.error,
              height: 1.4,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            label: context.l10n.text('dbRetry'),
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(_briefingPlanProvider),
          ),
        ],
      );
    }
    final plan = planAsync.valueOrNull;
    final explanation = plan != null && plan.rationale.isNotEmpty
        ? plan.rationale.first
        : 'No suitable targets meet tonight’s planning constraints.';
    final needsLocation = explanation.toLowerCase().contains('location');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          explanation,
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Align(
          alignment: Alignment.centerLeft,
          child: SkotiqButton(
            label: context.l10n
                .text(needsLocation ? 'dbSetLocation' : 'dbOpenPlanner'),
            icon: needsLocation ? LucideIcons.mapPin : LucideIcons.arrowRight,
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
            // Deep-link to the Location section. Plain '/settings' lands on
            // General and leaves the user hunting for the one field the button
            // just promised to set.
            onPressed: () => context.go(
              needsLocation ? '/settings?section=location' : '/planner',
            ),
          ),
        ),
      ],
    );
  }

  Widget _planBody(BuildContext context, SessionOptimizationPlan plan) {
    final primary = plan.primaryTarget!;
    final alternates = plan.alternates.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Primary target, prominent.
        Text(
          primary.targetName,
          style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          [
            if (primary.catalogId != null) primary.catalogId!,
            if (primary.objectType != null) primary.objectType!,
          ].join(' · '),
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Row(
          children: [
            _Stat(
              colors: colors,
              label: context.l10n.text('dbExposure'),
              value: plan.recommendedExposureSeconds > 0
                  ? '${plan.recommendedExposureSeconds.toStringAsFixed(0)}s'
                  : '--',
            ),
            const SizedBox(width: SkotiqTokens.spaceLg),
            _Stat(
              colors: colors,
              label: context.l10n.text('dbUsable'),
              value: plan.estimatedUsableHours > 0
                  ? '${plan.estimatedUsableHours.toStringAsFixed(1)}h'
                  : '--',
            ),
            const SizedBox(width: SkotiqTokens.spaceLg),
            _Stat(
              colors: colors,
              label: context.l10n.text('dbScore'),
              value: primary.totalScore.toStringAsFixed(0),
            ),
          ],
        ),
        if (alternates.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          Divider(height: 1, color: colors.border),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (final alt in alternates) ...[
            _AlternateRow(colors: colors, target: alt),
            const SizedBox(height: 4),
          ],
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        Align(
          alignment: Alignment.centerRight,
          child: SkotiqButton(
            label: context.l10n.text('dbOpenPlanner'),
            icon: LucideIcons.arrowRight,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => context.go('/planner'),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;

  const _Stat({
    required this.colors,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style:
              SkotiqTypography.overline.copyWith(color: colors.textMuted),
        ),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.monoSm.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _AlternateRow extends StatelessWidget {
  final SkotiqColors colors;
  final TargetSuggestion target;

  const _AlternateRow({required this.colors, required this.target});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(LucideIcons.dot, size: 16, color: colors.textMuted),
        const SizedBox(width: 2),
        Expanded(
          child: Text(
            target.catalogId ?? target.targetName,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          target.totalScore.toStringAsFixed(0),
          style: SkotiqTypography.withTabular(
            SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}
