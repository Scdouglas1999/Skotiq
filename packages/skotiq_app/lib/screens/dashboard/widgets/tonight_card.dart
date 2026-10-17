import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/plan_tonight_sequencer_helper.dart';
import '../../../utils/snackbar_helper.dart';
import '../../planetarium/show_in_sky.dart';
import '../../sequencer/widgets/smart_night_dialog.dart';
import 'glass_card.dart';

final _tonightOptimizationPlanProvider =
    FutureProvider.autoDispose<SessionOptimizationPlan>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  if (!settings.hasObserverLocation) {
    return SessionOptimizationPlan(
      generatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      primaryTarget: null,
      alternates: [],
      recommendedExposureSeconds: 0,
      estimatedUsableHours: 0,
      rationale: ['Set an observing location to generate target plans.'],
      riskFactors: [],
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

class TonightCard extends ConsumerWidget {
  final SkotiqColors colors;

  const TonightCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final twilight = ref.watch(twilightTimesProvider);
    final moonInfo = ref.watch(moonInfoProvider);
    final optimizationAsync = ref.watch(_tonightOptimizationPlanProvider);
    final optimization = optimizationAsync.valueOrNull;

    final String targetValue;
    if (optimizationAsync.isLoading) {
      targetValue = 'Planning...';
    } else if (optimizationAsync.hasError) {
      targetValue = 'Plan unavailable';
    } else if (optimization?.primaryTarget != null) {
      targetValue = optimization!.primaryTarget!.targetName;
    } else if (optimization?.rationale.any(
          (reason) => reason.toLowerCase().contains('location'),
        ) ??
        false) {
      targetValue = 'Location needed';
    } else {
      targetValue = 'No match tonight';
    }

    // Use select() to only watch the time field
    final now = ref.watch(observationTimeProvider.select((s) => s.time));

    // Twilight and the dark window are functions of the SITE. With no location
    // set the observer providers fall back to 0°N 0°E, which yields a perfectly
    // plausible equatorial dusk and a ~9h window — numbers a user would plan a
    // night around and that belong to nobody. Gate them on the same predicate
    // the Target row already uses (appObserverLocationProvider is null until a
    // real site exists) and show the placeholder instead. Moon illumination is
    // a phase, not a site quantity, so it stays.
    final hasSite = ref.watch(appObserverLocationProvider) != null;

    // Settings → Location → Timezone already drives the status bar, the header
    // chip, the night timeline and the moon card. This card sits among them,
    // so a twilight time left on the host's clock would show the operator two
    // different zones on one screen with nothing saying which is which.
    final clock = ref.watch(clockProvider);
    String hhmm(DateTime t) {
      final shown = clock.fromUtc(t.toUtc());
      return '${shown.hour.toString().padLeft(2, '0')}:'
          '${shown.minute.toString().padLeft(2, '0')}';
    }

    // Format astro twilight time
    String astroTwilightTime = kReadoutUnknown;
    if (hasSite && twilight.astronomicalDusk != null) {
      final dusk = twilight.astronomicalDusk!;
      // If dusk is in the future (relative to simulation time), show it
      if (dusk.isAfter(now)) {
        astroTwilightTime = hhmm(dusk);
      } else {
        // Dusk already passed, show dawn
        if (twilight.astronomicalDawn != null) {
          astroTwilightTime = hhmm(twilight.astronomicalDawn!);
        }
      }
    }

    // Format moon info - compact version without moonrise time
    final moonValue = '${moonInfo.illumination.toStringAsFixed(0)}%';

    // Calculate imaging window (darkness duration)
    String imagingWindow = kReadoutUnknown;
    if (hasSite &&
        twilight.astronomicalDusk != null &&
        twilight.astronomicalDawn != null) {
      final duration =
          twilight.astronomicalDawn!.difference(twilight.astronomicalDusk!);
      final hours = duration.inHours;
      final minutes = duration.inMinutes % 60;
      imagingWindow = '${hours}h ${minutes}m';
    }

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.moon,
            title: 'Tonight',
            accent: colors.warning,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          _TonightRow(
            icon: LucideIcons.sunset,
            label: 'Twilight',
            value: astroTwilightTime,
            colors: colors,
          ),
          const SizedBox(height: 6),
          _TonightRow(
            icon: LucideIcons.moonStar,
            label: 'Moon',
            value: moonValue,
            colors: colors,
          ),
          const SizedBox(height: 6),
          _TonightRow(
            icon: LucideIcons.timer,
            label: 'Window',
            value: imagingWindow,
            colors: colors,
          ),
          const SizedBox(height: 6),
          _TonightRow(
            icon: LucideIcons.target,
            label: 'Target',
            value: targetValue,
            colors: colors,
          ),
          const SizedBox(height: 6),
          _TonightRow(
            icon: LucideIcons.camera,
            label: 'Exposure',
            value: optimization == null || !optimization.hasRecommendation
                ? '--'
                : '${optimization.recommendedExposureSeconds.toStringAsFixed(0)}s',
            colors: colors,
          ),
          if (optimization != null && optimization.hasRecommendation) ...[
            const SizedBox(height: 6),
            _TonightRow(
              icon: LucideIcons.aperture,
              label: 'Filters',
              value: _formatRecommendedFilters(optimization),
              colors: colors,
            ),
          ],
          if (optimization != null && optimization.rationale.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              optimization.rationale.first,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ],
          if (optimizationAsync.hasError) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Couldn’t generate tonight’s plan.',
                    style:
                        SkotiqTypography.caption.copyWith(color: colors.error),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      ref.invalidate(_tonightOptimizationPlanProvider),
                  icon: const Icon(LucideIcons.refreshCw, size: 13),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ],
          if (optimization != null && optimization.alternates.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '+ ${optimization.alternates.length} more target${optimization.alternates.length == 1 ? '' : 's'}',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
          if (optimization != null && optimization.hasRecommendation) ...[
            const SizedBox(height: 10),
            _TonightTargetActions(
              colors: colors,
              target: optimization.primaryTarget!,
              onSendToFraming: () => _sendPrimaryToFraming(
                  context, ref, optimization.primaryTarget!),
              onShowInSky: () =>
                  _showPrimaryInSky(context, ref, optimization.primaryTarget!),
              onAddToSequencer: () => _addPrimaryToSequencer(
                context,
                ref,
                optimization.primaryTarget!,
                optimization,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () => context.go('/planner'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'See Full Plan',
                        style: SkotiqTypography.labelSm.copyWith(
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        LucideIcons.arrowRight,
                        size: 14,
                        color: colors.primary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          _SmartNightTonightAction(colors: colors),
        ],
      ),
    );
  }

  void _sendPrimaryToFraming(
    BuildContext context,
    WidgetRef ref,
    TargetSuggestion target,
  ) {
    ref.read(framingProvider.notifier).setTargetSuggestion(target);
    context.goNamed('framing');
  }

  /// Sky-context counterpart to "Frame target": jump to tonight's pick in the
  /// planetarium so the operator can see where it actually sits before
  /// committing the night to it.
  void _showPrimaryInSky(
    BuildContext context,
    WidgetRef ref,
    TargetSuggestion target,
  ) {
    showTargetInSky(
      context,
      ref,
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      name: target.targetName,
    );
  }

  Future<void> _addPrimaryToSequencer(
    BuildContext context,
    WidgetRef ref,
    TargetSuggestion target,
    SessionOptimizationPlan plan,
  ) async {
    try {
      final currentSequence = ref.read(currentSequenceProvider);
      if (currentSequence != null &&
          _sequenceAlreadyContainsTarget(currentSequence, target)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
              content: Text('${target.targetName} is already in sequence.')),
        );
        return;
      }
      final built = await buildPlanTonightTargetSequence(
        ref: ref,
        target: target,
        plan: plan,
      );
      if (!context.mounted) return;
      final added = await loadPlanTonightSequenceIntoEditor(
        context: context,
        ref: ref,
        result: built,
        replaceSequence: false,
      );

      if (added && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Added ${target.targetName} to sequence '
              '(${planTonightSequenceSummary(built)})',
            ),
          ),
        );
      }
    } on SmartNightBuildException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not add target to sequence: $e')),
        );
      }
    }
  }
}

bool _sequenceAlreadyContainsTarget(
  Sequence sequence,
  TargetSuggestion target,
) {
  final targetNames = <String>{
    _normalizedTargetName(target.targetName),
    if (target.catalogId != null) _normalizedTargetName(target.catalogId!),
  }..remove('');
  for (final node in sequence.nodes.values.whereType<TargetHeaderNode>()) {
    if (targetNames.contains(_normalizedTargetName(node.targetName))) {
      return true;
    }
    final raDeltaHours = (node.raHours - target.raHours).abs();
    final wrappedRaDeltaHours =
        raDeltaHours > 12 ? 24 - raDeltaHours : raDeltaHours;
    if (wrappedRaDeltaHours * 15 < 1 / 3600 &&
        (node.decDegrees - target.decDegrees).abs() < 1 / 3600) {
      return true;
    }
  }
  return false;
}

String _normalizedTargetName(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

class _SmartNightTonightAction extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _SmartNightTonightAction({required this.colors});

  @override
  ConsumerState<_SmartNightTonightAction> createState() =>
      _SmartNightTonightActionState();
}

class _SmartNightTonightActionState
    extends ConsumerState<_SmartNightTonightAction> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final locked = _sequenceIsActive(executionState);
    final lookup = profile == null
        ? null
        : SmartNightDraftLookup(
            profileId: profile.id?.toString() ?? profile.name,
            astronomicalDay: _astronomicalDay(DateTime.now()),
          );
    final draftAsync = lookup == null
        ? const AsyncValue<SmartNightDraft?>.data(null)
        : ref.watch(pendingSmartNightDraftProvider(lookup));
    final draft = draftAsync.valueOrNull;
    final label = locked
        ? 'Sequence running'
        : draft == null
            ? 'Plan tonight'
            : 'View tonight\'s plan';
    final icon = locked
        ? LucideIcons.lock
        : draft == null
            ? LucideIcons.sparkles
            : LucideIcons.fileClock;

    return Align(
      alignment: Alignment.centerRight,
      child: SkotiqButton(
        label: label,
        icon: icon,
        variant: ButtonVariant.primary,
        size: ButtonSize.small,
        isLoading: _busy,
        onPressed: locked || _busy
            ? null
            : draft == null
                ? () => _openPlanner(lookup)
                : () => _loadDraft(draft),
      ),
    );
  }

  Future<void> _openPlanner(SmartNightDraftLookup? lookup) async {
    setState(() => _busy = true);
    try {
      await showSmartNightDialog(context);
      if (lookup != null) {
        ref.invalidate(pendingSmartNightDraftProvider(lookup));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadDraft(SmartNightDraft draft) async {
    setState(() => _busy = true);
    try {
      final editor = ref.read(currentSequenceProvider.notifier);
      try {
        editor.loadSequence(draft.plan.sequence);
      } on UnsavedChangesException catch (e) {
        if (!mounted) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            content: ConstrainedBox(
              constraints: AdaptiveDialogConstraints.hybrid(
                dialogContext,
                designMaxWidth: 440,
              ),
              child: Text(
                '"${e.currentSequenceName}" has unsaved changes. '
                'Open tonight\'s Smart Night plan anyway?',
              ),
            ),
            actions: [
              SkotiqButton(
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              SkotiqButton(
                label: 'Discard and open',
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
          ),
        );
        if (discard != true || !mounted) return;
        editor.loadSequence(draft.plan.sequence, discardUnsaved: true);
      }
      if (!mounted) return;
      context.showSuccessSnackBar(
        'Smart Night plan loaded - '
        '${draft.plan.plannedTargets.length} '
        'target${draft.plan.plannedTargets.length == 1 ? '' : 's'}, '
        '${(draft.plan.totalIntegrationSecs / 3600).toStringAsFixed(1)}h.',
      );
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not load Smart Night plan: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

bool _sequenceIsActive(SequenceExecutionState state) {
  switch (state) {
    case SequenceExecutionState.idle:
    case SequenceExecutionState.completed:
    case SequenceExecutionState.failed:
      return false;
    case SequenceExecutionState.running:
    case SequenceExecutionState.paused:
    case SequenceExecutionState.stopping:
    case SequenceExecutionState.recovering:
    // A failed stop (hardware possibly still imaging), a pending cleanup, or an
    // in-flight finalization are all "active" — Tonight must not offer to launch
    // over a run that has not settled.
    case SequenceExecutionState.stopFailed:
    case SequenceExecutionState.cleanupFailed:
    case SequenceExecutionState.finalizing:
      return true;
  }
}

DateTime _astronomicalDay(DateTime now) {
  final local = now.toLocal();
  final day = local.hour < 12 ? local.subtract(const Duration(days: 1)) : local;
  return DateTime.utc(day.year, day.month, day.day);
}

String _formatRecommendedFilters(SessionOptimizationPlan plan) {
  if (plan.recommendedFilterNames.isNotEmpty) {
    return plan.recommendedFilterNames.join(' · ');
  }
  if (plan.recommendedFilterName != null) {
    return plan.recommendedFilterName!;
  }
  // No named filters anywhere on the rig — the plan will capture unfiltered.
  return 'No filter';
}

class _TonightTargetActions extends StatefulWidget {
  final SkotiqColors colors;
  final TargetSuggestion target;
  final VoidCallback onSendToFraming;
  final VoidCallback onShowInSky;
  final Future<void> Function() onAddToSequencer;

  const _TonightTargetActions({
    required this.colors,
    required this.target,
    required this.onSendToFraming,
    required this.onShowInSky,
    required this.onAddToSequencer,
  });

  @override
  State<_TonightTargetActions> createState() => _TonightTargetActionsState();
}

class _TonightTargetActionsState extends State<_TonightTargetActions> {
  bool _adding = false;

  Future<void> _addToSequencer() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await widget.onAddToSequencer();
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            widget.target.catalogId ?? widget.target.targetName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.caption
                .copyWith(color: widget.colors.textMuted),
          ),
        ),
        SkotiqIconButton(
          icon: LucideIcons.frame,
          tooltip: 'Frame target',
          size: IconButtonSize.sm,
          color: widget.colors.primary,
          onPressed: _adding ? null : widget.onSendToFraming,
        ),
        SkotiqIconButton(
          icon: LucideIcons.globe,
          tooltip: context.l10n.text('plannerOpenPlanetarium'),
          size: IconButtonSize.sm,
          color: widget.colors.primary,
          onPressed: _adding ? null : widget.onShowInSky,
        ),
        // Mid-add the button keeps its slot and shows the spinner in place of
        // the glyph, so the row never reflows under the pointer.
        if (_adding)
          SizedBox.square(
            dimension: SkotiqTokens.iconButtonSizeSm,
            child: Center(
              child: SizedBox.square(
                dimension: 15,
                child: SkotiqSpinner(size: 15, color: widget.colors.primary),
              ),
            ),
          )
        else
          SkotiqIconButton(
            icon: LucideIcons.listPlus,
            tooltip: 'Add to sequence',
            size: IconButtonSize.sm,
            color: widget.colors.primary,
            onPressed: _addToSequencer,
          ),
      ],
    );
  }
}

class _TonightRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;

  const _TonightRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: colors.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          value,
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textPrimary,
          ),
        ),
      ],
    );
  }
}
