import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../../utils/plan_tonight_sequencer_helper.dart';
import '../planetarium/show_in_sky.dart';
import 'one_tap_target_provider.dart';
import 'one_tap_tonight_controller.dart';

/// The opinionated one-tap "image this target tonight" screen.
///
/// One screen, one decision, one primary action. It picks tonight's best
/// target (the same pick the autopilot would slew to), shows a single confirm
/// card, and a GO button that chains auto-frame → Smart Night plan → start the
/// unattended run. The morning report is surfaced as the payoff.
///
/// This does NOT replace the deep planner/sequencer — an "Advanced" link keeps
/// the full toolset one tap away.
class TonightScreen extends ConsumerStatefulWidget {
  const TonightScreen({super.key});

  @override
  ConsumerState<TonightScreen> createState() => _TonightScreenState();
}

class _TonightScreenState extends ConsumerState<TonightScreen> {
  OneTapTonightController? _controller;

  /// Build the live controller lazily once `ref` is usable. The seams are
  /// wired to the real providers/helpers here, where a [WidgetRef] is in hand.
  OneTapTonightController _liveController() {
    return _controller ??= OneTapTonightController(
      pick: () async {
        final target = await ref.read(oneTapTargetProvider.future);
        if (target != null) return target;
        // An empty pick with no site configured is not "the sky is empty" —
        // the suggestion pipeline bails before it looks at the sky. Say which
        // it is instead of listing every possible cause.
        final settings = await ref.read(appSettingsProvider.future);
        if (!settings.hasObserverLocation) {
          throw const NoTonightTargetException(
            'Your observing location is not set, so Skotiq cannot tell '
            'what is above your horizon. Set your latitude and longitude in '
            'Settings → Location.',
          );
        }
        return null;
      },
      frame: (target) =>
          ref.read(framingProvider.notifier).setTargetSuggestion(target),
      plan: (target) => buildPlanTonightTargetSequenceFromSuggestion(
        ref: ref,
        target: target,
      ),
      run: (plan) async {
        // Non-destructive hand-off: takeOwnership stashes any unsaved manual
        // sequence and restores it when the run stops, instead of silently
        // discarding the operator's draft.
        ref.read(currentSequenceProvider.notifier).takeOwnership(
              plan.sequence,
              ActivePlanOwner.smartNight,
            );
        await ref.read(sequenceExecutorProvider).start();
      },
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final controller = _liveController();
    final targetAsync = ref.watch(oneTapTargetProvider);
    final activeSessionId = ref.watch(sessionStateProvider).dbSessionId;
    final AsyncValue<int?> morningSessionAsync;
    if (activeSessionId != null) {
      morningSessionAsync = AsyncData<int?>(activeSessionId);
    } else {
      morningSessionAsync = ref
          .watch(allSessionsProvider)
          .whenData((sessions) => sessions.firstOrNull?.id);
    }

    // The one-tap controller is created per screen mount, so after the user
    // taps "Watch on dashboard" and navigates back a fresh (idle) controller
    // would re-arm GO over a live run — a second tap then re-picks a target
    // and re-takes ownership mid-run. Watch the global execution state so the
    // primary action reflects reality regardless of this controller's phase.
    // running OR paused both count as active (same rule as sequencer_screen).
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final runActive = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused;
    final planOwner = ref.watch(activePlanOwnerProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            // Only override GO when a run is live that this controller isn't
            // itself narrating via [OneTapPhase.running]. Distinguish the copy:
            // a Smart Night owner is tonight's own plan ("Running tonight"),
            // anything else is an unrelated sequence.
            final TonightActiveRun? activeRun =
                (runActive && controller.state.phase != OneTapPhase.running)
                    ? (planOwner == ActivePlanOwner.smartNight
                        ? TonightActiveRun.ours
                        : TonightActiveRun.other)
                    : null;
            return TonightBodyView(
              colors: colors,
              state: controller.state,
              activeRun: activeRun,
              targetAsync: targetAsync,
              onGo: controller.go,
              onReset: controller.reset,
              onRefreshPick: () => ref.invalidate(oneTapTargetProvider),
              morningSessionAsync: morningSessionAsync,
              onRefreshMorningReport: () => ref.invalidate(allSessionsProvider),
            );
          },
        ),
      ),
    );
  }
}

/// A sequence run that is already live when the screen (re)builds but which
/// this screen's one-tap controller is not itself tracking as
/// [OneTapPhase.running] — a fresh controller after the user tapped "Watch on
/// dashboard" and navigated back, or a run started on another surface. Non-null
/// forces the primary action's running branch so GO cannot re-arm over it.
enum TonightActiveRun {
  /// The live run is the Smart Night / one-tap plan this screen launches, so
  /// "Running tonight" stays truthful.
  ours,

  /// A different sequence (manual authoring, autopilot, mosaic) owns the live
  /// run; the copy says so plainly instead of claiming tonight's plan.
  other,
}

/// Stateless body so a golden test (and any future seeded preview) can drive
/// it with a seeded [OneTapTonightState] + [AsyncValue] without spinning up the
/// live providers, framing assistant, or executor.
class TonightBodyView extends StatelessWidget {
  final SkotiqColors colors;
  final OneTapTonightState state;

  /// A live run this screen's controller isn't itself narrating; derived from
  /// the global execution state so a re-mounted (idle) controller doesn't
  /// re-arm GO. Passed in (not watched here) to keep this body seedable.
  final TonightActiveRun? activeRun;
  final AsyncValue<TargetSuggestion?> targetAsync;
  final Future<void> Function() onGo;
  final VoidCallback onReset;
  final VoidCallback onRefreshPick;
  final AsyncValue<int?> morningSessionAsync;
  final VoidCallback onRefreshMorningReport;

  const TonightBodyView({
    super.key,
    required this.colors,
    required this.state,
    required this.activeRun,
    required this.targetAsync,
    required this.onGo,
    required this.onReset,
    required this.onRefreshPick,
    required this.morningSessionAsync,
    required this.onRefreshMorningReport,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      children: [
        _Header(colors: colors),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _TargetConfirmCard(
          colors: colors,
          state: state,
          targetAsync: targetAsync,
          onRefreshPick: onRefreshPick,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _PrimaryAction(
          colors: colors,
          state: state,
          activeRun: activeRun,
          targetAsync: targetAsync,
          onGo: onGo,
          onReset: onReset,
        ),
        if (state.error != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ErrorBanner(colors: colors, message: state.error!),
        ],
        const SizedBox(height: SkotiqTokens.spaceXl),
        _MorningPayoff(
          colors: colors,
          running: state.phase == OneTapPhase.running,
          sessionAsync: morningSessionAsync,
          onRetry: onRefreshMorningReport,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _AdvancedFooter(colors: colors),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final SkotiqColors colors;
  const _Header({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.moonStar, size: 22, color: colors.primary),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              'Tonight',
              style:
                  SkotiqTypography.h2.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'One tap and Skotiq frames, plans, and runs the best target for '
          'you. Wake up to a finished master.',
          style:
              SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// The single confirm card: which target the chain will image, and why.
class _TargetConfirmCard extends StatelessWidget {
  final SkotiqColors colors;
  final OneTapTonightState state;
  final AsyncValue<TargetSuggestion?> targetAsync;
  final VoidCallback onRefreshPick;

  const _TargetConfirmCard({
    required this.colors,
    required this.state,
    required this.targetAsync,
    required this.onRefreshPick,
  });

  @override
  Widget build(BuildContext context) {
    // Once the chain is running it owns the headline target; before that the
    // confirm card mirrors the live pick provider.
    final running = state.target;
    if (running != null && state.phase != OneTapPhase.idle) {
      return _cardForTarget(running);
    }
    return targetAsync.when(
      loading: () => const _SkeletonCard(),
      error: (e, _) => _NoTargetCard(
        colors: colors,
        title: 'Could not pick a target',
        body: '$e',
        onAction: onRefreshPick,
      ),
      data: (target) {
        if (target == null) {
          return _NoPickCard(colors: colors, onRetry: onRefreshPick);
        }
        return _cardForTarget(target);
      },
    );
  }

  Widget _cardForTarget(TargetSuggestion target) {
    final peakAlt =
        target.visibility.peakAltitude ?? target.visibility.currentAltitude;
    final hoursAbove = target.visibility.hoursAboveMinAlt ?? 0.0;
    final ra = CoordinateUtils.formatRA(target.raHours);
    final dec = CoordinateUtils.formatDec(target.decDegrees);

    return SkotiqCard(
      variant: CardVariant.elevated,
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.radar,
                  size: SkotiqTokens.iconXs, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                "TONIGHT'S PICK",
                style: SkotiqTypography.overline
                    .copyWith(color: colors.primary),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            target.targetName,
            style: SkotiqTypography.h3.copyWith(color: colors.textPrimary),
          ),
          if (target.objectType != null) ...[
            const SizedBox(height: 2),
            Text(
              target.objectType!,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              StatusPill(
                icon: LucideIcons.arrowUpRight,
                label: 'Peak alt',
                value: '${peakAlt.toStringAsFixed(0)}°',
              ),
              StatusPill(
                icon: LucideIcons.clock,
                label: 'Hours up',
                value: '${hoursAbove.toStringAsFixed(1)} h',
              ),
              StatusPill(
                icon: LucideIcons.crosshair,
                label: 'RA / Dec',
                value: '$ra  $dec',
              ),
            ],
          ),
          if (target.reasoning.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              target.reasoning,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary, height: 1.4),
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          // The one-tap screen deliberately hides the toolset, but "where is
          // this thing?" is a fair question to ask before handing the rig a
          // whole night. One link out to the sky, then back.
          Align(
            alignment: Alignment.centerLeft,
            child: Consumer(
              builder: (context, ref, _) => SkotiqButton(
                label: context.l10n.text('plannerOpenPlanetarium'),
                icon: LucideIcons.globe,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => showTargetInSky(
                  context,
                  ref,
                  raHours: target.raHours,
                  decDegrees: target.decDegrees,
                  name: target.targetName,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The single primary action. One button. Its label narrates the active
/// phase so progress is legible without a second control.
class _PrimaryAction extends StatelessWidget {
  final SkotiqColors colors;
  final OneTapTonightState state;
  final TonightActiveRun? activeRun;
  final AsyncValue<TargetSuggestion?> targetAsync;
  final Future<void> Function() onGo;
  final VoidCallback onReset;

  const _PrimaryAction({
    required this.colors,
    required this.state,
    required this.activeRun,
    required this.targetAsync,
    required this.onGo,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final hasPick = targetAsync.valueOrNull != null || state.target != null;

    // A run is live — either this chain reached [OneTapPhase.running], or an
    // external run is active while this (possibly freshly mounted) controller
    // has not itself started it. Either way GO must not re-arm.
    if (state.phase == OneTapPhase.running || activeRun != null) {
      final headline = activeRun == TonightActiveRun.other
          ? 'A sequence is already running'
          : 'Running tonight';
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.checkCircle2, size: 18, color: colors.success),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                headline,
                style: SkotiqTypography.bodyMedium.copyWith(
                  color: colors.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          // The dashboard cockpit is the monitoring surface — hand the user
          // straight back to it so the GO → watch-it-run loop closes on one
          // screen instead of bouncing through Imaging.
          SkotiqButton(
            label: 'Watch on dashboard',
            icon: LucideIcons.layoutDashboard,
            variant: ButtonVariant.outline,
            size: ButtonSize.large,
            onPressed: () => context.go('/dashboard'),
          ),
        ],
      );
    }

    if (state.phase == OneTapPhase.failed) {
      return SkotiqButton(
        label: 'Try again',
        icon: LucideIcons.refreshCw,
        variant: ButtonVariant.primary,
        size: ButtonSize.large,
        onPressed: () {
          onReset();
          onGo();
        },
      );
    }

    return SkotiqButton(
      label: _label(state.phase),
      icon: state.isBusy ? null : LucideIcons.play,
      variant: ButtonVariant.primary,
      size: ButtonSize.large,
      isLoading: state.isBusy,
      onPressed: (hasPick && !state.isBusy) ? onGo : null,
    );
  }

  String _label(OneTapPhase phase) {
    switch (phase) {
      case OneTapPhase.picking:
        return 'Choosing target…';
      case OneTapPhase.framing:
        return 'Framing…';
      case OneTapPhase.planning:
        return 'Planning the night…';
      case OneTapPhase.starting:
        return 'Starting run…';
      case OneTapPhase.idle:
      case OneTapPhase.running:
      case OneTapPhase.failed:
        return 'Image this target tonight';
    }
  }
}

/// The morning payoff: a path to the morning report / session review.
class _MorningPayoff extends StatelessWidget {
  final SkotiqColors colors;
  final bool running;
  final AsyncValue<int?> sessionAsync;
  final VoidCallback onRetry;

  const _MorningPayoff({
    required this.colors,
    required this.running,
    required this.sessionAsync,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return sessionAsync.when(
      loading: () => _MorningPayoffStatus(
        colors: colors,
        icon: LucideIcons.loader2,
        title: 'Loading morning report…',
      ),
      error: (error, _) => _MorningPayoffStatus(
        colors: colors,
        icon: LucideIcons.alertTriangle,
        title: 'Morning report unavailable',
        body: '$error',
        onRetry: onRetry,
      ),
      data: (sessionId) {
        if (sessionId == null) return const SizedBox.shrink();
        return _reportCard(context, sessionId);
      },
    );
  }

  Widget _reportCard(BuildContext context, int sessionId) {
    return SkotiqCard(
      variant: CardVariant.subtle,
      onTap: () => context.push('/session-review?session=$sessionId'),
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Row(
        children: [
          Icon(LucideIcons.sunrise, size: 20, color: colors.warning),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Morning report',
                  style: SkotiqTypography.bodyMedium.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  running
                      ? "When the night wraps, your graded master and a full "
                          'briefing land here.'
                      : 'Last night graded, stacked, and explained — see your '
                          'best frames and what to improve.',
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
          Icon(LucideIcons.chevronRight, size: 18, color: colors.textSecondary),
        ],
      ),
    );
  }
}

class _MorningPayoffStatus extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;
  final String? body;
  final VoidCallback? onRetry;

  const _MorningPayoffStatus({
    required this.colors,
    required this.icon,
    required this.title,
    this.body,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      variant: CardVariant.subtle,
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Row(
        children: [
          Icon(icon,
              size: 20, color: onRetry == null ? colors.warning : colors.error),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.bodyMedium.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (body != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    body!,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry report'),
            ),
        ],
      ),
    );
  }
}

/// Keeps the deep planner/sequencer one tap away (never replaced).
class _AdvancedFooter extends StatelessWidget {
  final SkotiqColors colors;
  const _AdvancedFooter({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton.icon(
          onPressed: () => context.go('/planner'),
          icon:
              Icon(LucideIcons.sliders, size: 15, color: colors.textSecondary),
          label: Text(
            'Advanced: full planner & sequencer',
            style: SkotiqTypography.bodySm
                .copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final SkotiqColors colors;
  final String message;

  const _ErrorBanner({required this.colors, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertCircle, size: 16, color: colors.error),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textPrimary, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the picker came back with nothing.
///
/// Do not hedge about a fact the app knows: with no site configured the
/// suggestion pipeline returns an empty list before it looks at the sky at all,
/// and Refresh can never change that. Name the missing location and offer a way
/// to fix it, as the planner, weather and dashboard do; keep the "nothing is
/// up" message for when the site IS set.
class _NoPickCard extends ConsumerWidget {
  final SkotiqColors colors;
  final VoidCallback onRetry;

  const _NoPickCard({required this.colors, required this.onRetry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final locationUnset = settings != null && !settings.hasObserverLocation;

    if (locationUnset) {
      return _NoTargetCard(
        colors: colors,
        icon: LucideIcons.mapPin,
        title: 'Location not configured',
        body: 'Skotiq cannot tell what is above your horizon until it '
            'knows where you are. Set your observing latitude and longitude '
            'in Settings.',
        actionLabel: 'Open settings',
        actionIcon: LucideIcons.mapPin,
        onAction: () => context.go('/settings?section=location'),
      );
    }

    return _NoTargetCard(
      colors: colors,
      icon: LucideIcons.cloudOff,
      title: 'Nothing imageable right now',
      body: 'Nothing in the catalog clears your horizon and moon limits at '
          'this moment. Try again later tonight, or widen the limits in '
          'Plan Tonight.',
      actionLabel: 'Refresh',
      actionIcon: LucideIcons.refreshCw,
      onAction: onRetry,
    );
  }
}

class _NoTargetCard extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final String body;
  final IconData icon;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  const _NoTargetCard({
    required this.colors,
    required this.title,
    required this.body,
    required this.onAction,
    this.icon = LucideIcons.cloudOff,
    this.actionLabel = 'Refresh',
    this.actionIcon = LucideIcons.refreshCw,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      variant: CardVariant.standard,
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.warning),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  title,
                  style: SkotiqTypography.bodyMedium
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            body,
            style: SkotiqTypography.bodySm
                .copyWith(color: colors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqButton(
            label: actionLabel,
            icon: actionIcon,
            variant: ButtonVariant.outline,
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return const SkotiqCard(
      variant: CardVariant.elevated,
      padding: EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(
              width: 110, height: 10, borderRadius: SkotiqTokens.radiusSm),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(
              width: 180, height: 20, borderRadius: SkotiqTokens.radiusSm),
          SizedBox(height: SkotiqTokens.spaceMd),
          SkeletonBox(
              width: double.infinity,
              height: 14,
              borderRadius: SkotiqTokens.radiusSm),
        ],
      ),
    );
  }
}
