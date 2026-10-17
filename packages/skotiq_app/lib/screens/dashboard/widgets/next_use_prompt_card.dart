import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'glass_card.dart';
import 'smart_night_prompt_card.dart'
    show
        floatingPromptClaimants,
        floatingPromptOwnersProvider,
        kFloatingPromptReservedHeight,
        smartNightOpticsReadyProvider;

const double _kDesktopPromptWidth = 480.0;
const double _kBottomInset = 16.0;
const double _kMobileHorizontalMargin = 16.0;

/// Maps a [NextUseStep.iconKey] (a Flutter-free stable string defined in
/// `skotiq_core`) to a concrete `lucide_icons` glyph.
///
/// Keeping the lookup here — at the presentation boundary — is what lets the
/// core model stay Flutter-free. Every key used by [kNextUseSteps] MUST appear
/// here; an unknown key surfaces as a [StateError] rather than silently
/// rendering a wrong or blank icon.
IconData _iconForKey(String iconKey) {
  switch (iconKey) {
    case 'sparkles':
      return LucideIcons.sparkles;
    case 'crop':
      return LucideIcons.crop;
    case 'crosshair':
      return LucideIcons.crosshair;
    case 'focus':
      return LucideIcons.focus;
    case 'camera':
      return LucideIcons.camera;
  }
  throw StateError(
    'No lucide icon mapped for NextUseStep iconKey "$iconKey". '
    'Every kNextUseSteps iconKey must be mapped in _iconForKey.',
  );
}

/// Post-onboarding "what should I do first?" nudge.
///
/// Surfaces the next first-real-use action ([nextUsePromptProvider]) once the
/// rig is ready and the first-launch coach is finished: a bottom-centre
/// [DashboardGlassCard] that slides and fades in, walking the user through
/// framing, solving, focus and first light. It shares that anchor with
/// [SmartNightPromptCard] and stands down whenever the Smart Night prompt is
/// eligible, which takes precedence.
///
/// Dismissal goes through [TutorialProgressDao.dismissPromptForScreen] on the
/// `next_use.<id>` screen id — the same write path
/// [nextUseDismissedActionsProvider] watches, so the prompt re-resolves to the
/// next eligible step (or nothing) the instant the user dismisses.
class NextUsePromptCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const NextUsePromptCard({super.key, required this.colors});

  @override
  ConsumerState<NextUsePromptCard> createState() => _NextUsePromptCardState();
}

class _NextUsePromptCardState extends ConsumerState<NextUsePromptCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Captured so dispose() can release this card's band claim without
    // touching `ref` after unmount (Riverpod forbids it); the owners provider
    // is not autoDispose, so the controller outlives this widget. Without
    // this, navigating away mid-prompt strands the tag and the reserve.
    _ownersController = ref.read(floatingPromptOwnersProvider.notifier);
    _animController = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationQuick,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _fade = CurvedAnimation(parent: _animController, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    // Release the band claim OUTSIDE the frame: element unmount runs inside
    // finalizeTree, where writing a provider trips riverpod's
    // modify-during-build guard. A microtask lands after the frame; if the
    // container itself is being torn down the claim dies with it.
    final controller = _ownersController;
    scheduleMicrotask(() {
      // A replacement instance publishing in the same frame has already
      // taken the claim (post-frame runs before this microtask) — releasing
      // then would wipe the LIVE card's band.
      if (!identical(floatingPromptClaimants[_promptOwnerTag], this)) return;
      floatingPromptClaimants.remove(_promptOwnerTag);
      try {
        if (controller.state.containsKey(_promptOwnerTag)) {
          controller.state = {...controller.state}..remove(_promptOwnerTag);
        }
      } on StateError {
        // Container already disposed — nothing left to clean.
      }
    });
    _animController.dispose();
    super.dispose();
  }

  static const _promptOwnerTag = 'next-use';

  late final StateController<Map<String, double>> _ownersController;

  /// Anchors the measurable card box (below the Align/inset wrappers and the
  /// slide/fade transforms, whose mid-animation position must not leak into
  /// the measurement).
  final _measureKey = GlobalKey();

  void _publishShowing(bool showing, {double bottomInset = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final owners = ref.read(floatingPromptOwnersProvider.notifier);
      final next = <String, double>{...owners.state};
      if (showing) {
        // Claim BEFORE the no-change short-circuit: a replacement instance
        // publishing the same band must still take ownership, or the old
        // instance's dispose release wipes the live claim.
        floatingPromptClaimants[_promptOwnerTag] = this;
        // Publish the band this card actually occupies: its rendered height
        // plus the inset it floats above (phone bottom nav included), so
        // the reserve follows the real card instead of a constant that can
        // cover neither a 108px card, a ~200px card, nor a nav inset at
        // once. Falls back to the legacy constant until layout lands.
        var band = kFloatingPromptReservedHeight;
        final box = _measureKey.currentContext?.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          band = box.size.height + bottomInset;
        }
        if (next[_promptOwnerTag] == band) return;
        next[_promptOwnerTag] = band;
      } else {
        if (!identical(floatingPromptClaimants[_promptOwnerTag], this)) return;
        floatingPromptClaimants.remove(_promptOwnerTag);
        if (!next.containsKey(_promptOwnerTag)) return;
        next.remove(_promptOwnerTag);
      }
      owners.state = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(nextUsePromptProvider);

    // First-use coaching must never compete with an unsettled imaging run. In
    // particular, this gate cannot live only inside Smart Night eligibility:
    // users who disable the Smart Night auto-prompt still have running,
    // paused, stopping, recovering, and cleanup/finalization states where a
    // "what should I do next?" action would be both distracting and unsafe.
    final sequenceActive =
        _sequenceIsActive(ref.watch(sequenceExecutionStateProvider));

    // De-overlap with the Smart Night prompt: both anchor bottom-centre, so
    // never stack them. Smart Night ("plan tonight") wins when it is eligible;
    // this card stands down. Mirrors the coach/readiness de-overlap in
    // dashboard_screen.dart. Suppressing on Smart Night's *base* eligibility
    // (not its post-grace visibility) is the conservative choice — at worst the
    // bottom-centre slot is briefly empty while Smart Night's grace elapses,
    // never double-occupied.
    final smartNightEligible = ref.watch(_smartNightPromptEligibleProvider);

    if (step == null || smartNightEligible || sequenceActive) {
      _animController.value = 0.0;
      _publishShowing(false);
      return const SizedBox.shrink();
    }

    // The two bottom-centre prompts are mutually exclusive by construction,
    // so they share one visibility signal: DashboardScrollView reserves the
    // prompt band off it, and without this publish the next-use nudge sat
    // over the last card in the extent (live: RECENT EVENTS rows at 1000x800)
    // with no way to scroll them out from under it.
    if (!_animController.isAnimating && _animController.value < 1.0) {
      _animController.forward();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile =
            constraints.maxWidth < BreakpointTokens.breakpointPhone;
        final cardWidth = isMobile
            ? constraints.maxWidth - (_kMobileHorizontalMargin * 2)
            : _kDesktopPromptWidth;
        final useBottomNav =
            ShellChrome.useBottomNavigation(constraints.maxWidth);
        final bottomInset = ShellChromeMetrics.floatingOverlayBottomInset(
          context,
          useBottomNav: useBottomNav,
          margin: _kBottomInset,
        );
        _publishShowing(true, bottomInset: bottomInset);

        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: bottomInset,
              left: _kMobileHorizontalMargin,
              right: _kMobileHorizontalMargin,
            ),
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: SizedBox(
                  key: _measureKey,
                  width: cardWidth,
                  // A text-scale bump, a longer localized string, or a font
                  // change rewraps the card WITHOUT re-running this builder
                  // (nothing up here depends on them), so the notifier is
                  // what keeps the published band tracking the real height.
                  child: NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: (_) {
                      _publishShowing(true, bottomInset: bottomInset);
                      return true;
                    },
                    child: SizeChangedLayoutNotifier(
                      child: _buildCard(context, step),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, NextUseStep step) {
    final colors = widget.colors;
    return DashboardGlassCard(
      colors: colors,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                decoration: SkotiqDecorations.iconChip(colors.primary),
                child: Icon(
                  _iconForKey(step.iconKey),
                  size: SkotiqTokens.iconSm,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  step.title,
                  style: SkotiqTypography.bodyMedium.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              _OverflowMenuButton(
                colors: colors,
                onSelected: (action) => _onMenuSelected(action, step),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Text(
              step.body,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // A Wrap, not a Row: the Observatory small button carries a 13px
          // label where the old one carried 11, and two of them plus an icon
          // no longer fit this card's width at the phone sizes the dashboard
          // is tested at. Wrapping onto a second run is the honest answer;
          // shrinking the labels would hide what the buttons do.
          Wrap(
            alignment: WrapAlignment.end,
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              SkotiqButton(
                // Not "Not now". This button calls the same _dismissStep as
                // the overflow menu's "Skip this step": it writes the
                // `next_use.<id>` dismissal row and the step never comes back.
                // "Not now" promises a deferral the card does not implement —
                // live on the dashboard, pressing it retired "Confirm your
                // plate solver" permanently and the prompt had moved on to the
                // next step after a screen change. Say what it does.
                label: 'Skip this step',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: _busy ? null : () => _dismissStep(step.id),
              ),
              SkotiqButton(
                label: step.actionLabel,
                icon: LucideIcons.arrowRight,
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                onPressed: _busy ? null : () => _takeAction(step),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _takeAction(NextUseStep step) {
    context.go(step.deepLinkRoute);
  }

  void _onMenuSelected(_PromptMenuAction action, NextUseStep step) {
    switch (action) {
      case _PromptMenuAction.dismissStep:
        _dismissStep(step.id);
      case _PromptMenuAction.dismissAll:
        _dismissAll();
    }
  }

  /// Permanently retire a single step by writing its `next_use.<id>` dismissal
  /// row. [nextUseDismissedActionsProvider] watches this table, so the prompt
  /// re-resolves to the next eligible step without manual invalidation.
  Future<void> _dismissStep(NextUseActionId id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dao = ref.read(tutorialProgressDaoProvider);
      await dao.dismissPromptForScreen(nextUsePromptScreenId(id));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Retire every currently-defined next-use step at once ("Hide all tips").
  Future<void> _dismissAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dao = ref.read(tutorialProgressDaoProvider);
      for (final id in NextUseActionId.values) {
        await dao.dismissPromptForScreen(nextUsePromptScreenId(id));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Whether the Smart Night prompt is base-eligible to occupy the bottom-centre
/// slot, so [NextUsePromptCard] can stand down.
///
/// Mirrors only the eligibility inputs [SmartNightPromptCard] exposes as public
/// providers. Its private equipment-ready grace timer and per-day "Not now"
/// dismissal are deliberately NOT mirrored: both only delay or hide Smart
/// Night, so treating it as eligible whenever the base conditions hold keeps
/// the two prompts mutually exclusive without ever double-showing.
final _smartNightPromptEligibleProvider = Provider<bool>((ref) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return false;

  final equipmentReady = ref.watch(smartNightOpticsReadyProvider);
  if (!equipmentReady) return false;

  final autoPromptEnabled =
      ref.watch(appSettingsProvider).valueOrNull?.smartNightAutoPromptEnabled ??
          false;
  if (!autoPromptEnabled) return false;

  final sequenceActive =
      _sequenceIsActive(ref.watch(sequenceExecutionStateProvider));
  if (sequenceActive) return false;

  final location = ref.watch(appObserverLocationProvider);
  if (location == null) return false;
  if (location.latitude == 0.0 && location.longitude == 0.0) return false;

  // Every public gate Smart Night requires now holds. Whether it ultimately
  // shows its "build tonight" or "resume tonight" prompt, Smart Night owns the
  // bottom-centre slot, so this card stands down. (Its draft lookup, grace
  // timer, and per-day dismissal only choose *which* prompt or *when* — never
  // whether the slot is contested.)
  return true;
});

enum _PromptMenuAction { dismissStep, dismissAll }

class _OverflowMenuButton extends StatelessWidget {
  final SkotiqColors colors;
  final ValueChanged<_PromptMenuAction> onSelected;

  const _OverflowMenuButton({
    required this.colors,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_PromptMenuAction>(
      tooltip: 'Prompt options',
      icon: Icon(
        LucideIcons.moreVertical,
        size: SkotiqTokens.iconSm,
        color: colors.textMuted,
      ),
      onSelected: onSelected,
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _PromptMenuAction.dismissStep,
          child: Text('Skip this step'),
        ),
        PopupMenuItem(
          value: _PromptMenuAction.dismissAll,
          child: Text('Hide all tips'),
        ),
      ],
    );
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
    // in-flight finalization are all "active" — the run is not settled (start is
    // blocked), so the next-use prompt must not offer to launch over it.
    case SequenceExecutionState.stopFailed:
    case SequenceExecutionState.cleanupFailed:
    case SequenceExecutionState.finalizing:
      return true;
  }
}
