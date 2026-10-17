import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../sequencer/widgets/smart_night_dialog.dart';
import 'glass_card.dart';

const double _kDesktopPromptWidth = 480.0;
const double _kBottomInset = 16.0;
const double _kMobileHorizontalMargin = 16.0;

/// Vertical space the dashboard's scroll view keeps clear while a floating
/// prompt is on screen.
///
/// The nudge is drawn OVER the dashboard, so at the bottom of the scroll extent
/// it covered the Moon card and hid the Moonrise time while leaving Moonset
/// visible — measured on the live frame at x 537-920 / y 537-645 over a Moon
/// card at x 258-722. Reserving its height (108 px measured, plus its bottom
/// margin) lets the last card scroll clear of it.
const double kFloatingPromptReservedHeight = 178.0 + _kBottomInset * 2;
const Duration _kSlideInDuration = Duration(milliseconds: 240);

final smartNightPromptGraceProvider =
    Provider<Duration>((ref) => const Duration(seconds: 60));

/// Wall-clock source for the equipment-ready grace window, injectable so tests
/// can advance time without sleeping.
///
/// MUST stay a *function*: a `Provider<DateTime>` is not autoDispose, so the
/// single `DateTime.now()` captured on its first read would be cached for the
/// life of the container and the grace window would never elapse.
final smartNightPromptClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// The cards currently claiming the bottom-centre floating-prompt band, by
/// owner tag, mapped to the band each one MEASURED after layout: viewport
/// bottom to its own top edge, so the bottom-nav inset and the card's real
/// height are both included. No constant can cover a Smart Night card, a
/// next-use step and a phone's nav inset at once.
///
/// A card adds its tag when it shows and removes ONLY its own tag when it
/// stands down, so one card's retraction can never clobber the other's claim —
/// the post-frame publishes race in arbitrary order.
final floatingPromptOwnersProvider =
    StateProvider<Map<String, double>>((ref) => const <String, double>{});

/// Which card State instance currently owns each band tag. Implementation
/// detail of the two prompt cards: a dispose-time release runs on a
/// MICROTASK (after the frame), while a same-frame replacement instance
/// publishes on a post-frame callback (inside the frame) — so a stale
/// release would otherwise wipe the live instance's claim. A release may
/// only act while its own instance is still the claimant.
final floatingPromptClaimants = <String, Object>{};

/// True while any bottom-centre prompt is floating.
final smartNightAutoPromptShowingProvider = Provider<bool>(
  (ref) => ref.watch(floatingPromptOwnersProvider).isNotEmpty,
);

/// The scroll extent DashboardScrollView and the standby header must reserve
/// so content can clear the floating prompt: the tallest published band,
/// zero when nothing is showing.
final floatingPromptReservedHeightProvider = Provider<double>((ref) {
  final bands = ref.watch(floatingPromptOwnersProvider).values;
  return bands.isEmpty ? 0.0 : bands.reduce((a, b) => a > b ? a : b);
});

/// Whether the active profile carries enough OPTICS to plan a night: a focal
/// length and an aperture, which is all Smart Night needs to derive field of
/// view and image scale.
///
/// Deliberately says nothing about whether any device is connected, and must
/// not be described as such on screen: planning a night indoors before the gear
/// is powered on is a real use, and a "hardware ready" caption over this gate
/// would contradict the Readiness panel beside it.
final smartNightOpticsReadyProvider = Provider<bool>((ref) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return false;
  final focalLength = profile.focalLength > 0
      ? profile.focalLength
      : (profile.telescopeFocalLength ?? 0);
  final aperture = profile.aperture > 0
      ? profile.aperture
      : (profile.telescopeAperture ?? 0);
  return focalLength > 0 && aperture > 0;
});

final _smartNightPromptDismissedDaysProvider =
    StateProvider<Set<String>>((ref) => <String>{});

class SmartNightPromptCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const SmartNightPromptCard({super.key, required this.colors});

  @override
  ConsumerState<SmartNightPromptCard> createState() =>
      _SmartNightPromptCardState();
}

class _SmartNightPromptCardState extends ConsumerState<SmartNightPromptCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  bool _busy = false;
  DateTime? _equipmentReadySince;
  Timer? _graceTimer;

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
      duration: _kSlideInDuration,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _fade = CurvedAnimation(parent: _animController, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
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

  /// Publish the prompt's real rendered visibility after the frame settles, so
  /// reading widgets (the standby header) rebuild without mutating provider
  /// state mid-build.
  static const _promptOwnerTag = 'smart-night';

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
    final profile = ref.watch(activeEquipmentProfileProvider);
    final location = ref.watch(appObserverLocationProvider);
    final autoPromptEnabled = ref
            .watch(appSettingsProvider)
            .valueOrNull
            ?.smartNightAutoPromptEnabled ??
        false;
    final sequenceActive =
        _sequenceIsActive(ref.watch(sequenceExecutionStateProvider));
    final equipmentReady = ref.watch(smartNightOpticsReadyProvider);
    final readyGraceElapsed = _equipmentReadyGraceElapsed(equipmentReady);
    final dayKey = _astronomicalDayKey(DateTime.now());
    final dismissedDays = ref.watch(_smartNightPromptDismissedDaysProvider);
    final persistedDismissedKey = ref
            .watch(appSettingsProvider)
            .valueOrNull
            ?.smartNightPromptDismissedDayKey ??
        '';

    final canPlan = equipmentReady &&
        readyGraceElapsed &&
        profile != null &&
        location != null &&
        !(location.latitude == 0.0 && location.longitude == 0.0);
    final baseShouldShow = canPlan &&
        autoPromptEnabled &&
        !sequenceActive &&
        !dismissedDays.contains(dayKey) &&
        persistedDismissedKey != dayKey;

    if (!baseShouldShow) {
      _animController.value = 0.0;
      _publishShowing(false);
      return const SizedBox.shrink();
    }

    final lookup = SmartNightDraftLookup(
      profileId: profile.id?.toString() ?? profile.name,
      astronomicalDay: _astronomicalDay(DateTime.now()),
    );
    final draftAsync = ref.watch(pendingSmartNightDraftProvider(lookup));
    if (draftAsync.isLoading || draftAsync.valueOrNull != null) {
      _animController.value = 0.0;
      _publishShowing(false);
      return const SizedBox.shrink();
    }

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
                      child: _buildCard(context, lookup),
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

  Widget _buildCard(
    BuildContext context,
    SmartNightDraftLookup lookup,
  ) {
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
                padding: const EdgeInsets.all(8),
                decoration: SkotiqDecorations.tintedBadge(
                  colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Icon(
                  LucideIcons.sparkles,
                  size: 16,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Build tonight\'s plan?',
                  style: SkotiqTypography.h5.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              _OverflowMenuButton(colors: colors, onSelected: _onMenuSelected),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Text(
              'Smart Night will choose targets, exposures, and filters '
              'from your gear and the sky tonight.',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SkotiqButton(
                label: 'Not now',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: _busy ? null : _dismissToday,
              ),
              const SizedBox(width: 8),
              SkotiqButton(
                label: 'Plan tonight',
                icon: LucideIcons.sparkles,
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                isLoading: _busy,
                onPressed: _busy ? null : () => _openPlanner(lookup),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openPlanner(SmartNightDraftLookup lookup) async {
    setState(() => _busy = true);
    try {
      await showSmartNightDialog(context);
      ref.invalidate(pendingSmartNightDraftProvider(lookup));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onMenuSelected(_PromptMenuAction action) {
    switch (action) {
      case _PromptMenuAction.dismissToday:
        _dismissToday();
      case _PromptMenuAction.disableOnConnect:
        ref
            .read(appSettingsProvider.notifier)
            .setSmartNightAutoPromptEnabled(false);
    }
  }

  void _dismissToday() {
    final dayKey = _astronomicalDayKey(DateTime.now());
    ref.read(_smartNightPromptDismissedDaysProvider.notifier).update(
          (days) => {...days, dayKey},
        );
    ref
        .read(appSettingsProvider.notifier)
        .setSmartNightPromptDismissedDayKey(dayKey);
  }

  bool _equipmentReadyGraceElapsed(bool equipmentReady) {
    if (!equipmentReady) {
      _equipmentReadySince = null;
      _graceTimer?.cancel();
      _graceTimer = null;
      return false;
    }

    final now = ref.watch(smartNightPromptClockProvider)();
    final grace = ref.watch(smartNightPromptGraceProvider);
    _equipmentReadySince ??= now;
    if (grace <= Duration.zero) {
      _graceTimer?.cancel();
      _graceTimer = null;
      return true;
    }

    final elapsed = now.difference(_equipmentReadySince!);
    if (elapsed >= grace) {
      _graceTimer?.cancel();
      _graceTimer = null;
      return true;
    }

    final remaining = grace - elapsed;
    // Clearing the handle from inside the callback is what lets the wake-up
    // RE-ARM. A fired Timer stays non-null, so the `??=` below would never
    // schedule another one and a rebuild that still fell short of the grace
    // would leave the card with nothing left to wake it.
    _graceTimer ??= Timer(remaining, () {
      _graceTimer = null;
      if (mounted) setState(() {});
    });
    return false;
  }
}

enum _PromptMenuAction { dismissToday, disableOnConnect }

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
      icon: Icon(LucideIcons.moreVertical, size: 16, color: colors.textMuted),
      onSelected: onSelected,
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _PromptMenuAction.dismissToday,
          child: Text('Hide for tonight'),
        ),
        PopupMenuItem(
          value: _PromptMenuAction.disableOnConnect,
          child: Text("Don't ask again on connect"),
        ),
      ],
    );
  }
}

DateTime _astronomicalDay(DateTime now) {
  final local = now.toLocal();
  final day = local.hour < 12 ? local.subtract(const Duration(days: 1)) : local;
  return DateTime.utc(day.year, day.month, day.day);
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
    // in-flight finalization are all "active" — Smart Night must not prompt to
    // launch over a run that has not settled.
    case SequenceExecutionState.stopFailed:
    case SequenceExecutionState.cleanupFailed:
    case SequenceExecutionState.finalizing:
      return true;
  }
}

String _astronomicalDayKey(DateTime now) {
  final day = _astronomicalDay(now);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${day.year}-${two(day.month)}-${two(day.day)}';
}
