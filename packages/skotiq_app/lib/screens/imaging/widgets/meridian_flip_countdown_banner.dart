import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Session-scoped record of the severity at which the operator dismissed the
/// meridian-flip banner. The banner stays hidden while the live severity is at
/// or below this level, and re-appears the moment the flip escalates to a more
/// urgent tone (info → warning → imminent) — so dismissing the calm "flip in
/// 5h" status can never suppress the attention-grade "imminent" one. Holds the
/// dismissed [SkotiqAlertSeverity.index]; `null` means "not dismissed". It
/// resets to `null` [MeridianFlipCountdownBanner.kDismissalResetGrace] after
/// the flip disarms — debounced so a heartbeat flap (disconnect → auto-reconnect
/// every ~30 s) cannot un-dismiss the banner — and resets immediately when the
/// reported pier side changes (the flip this countdown was for has happened,
/// so a fresh cycle starts clean). Deliberately NOT persisted (a new night
/// starts clean).
final meridianBannerDismissedSeverityProvider =
    StateProvider<int?>((ref) => null);

/// The meridian-flip countdown, at the two weights it can need.
///
/// A calm, far-off countdown ("flip in 3h 6m", or armed against a tracking
/// limit with no countdown) needs no action, so it is a compact
/// [MeridianFlipChip] in the viewer toolbar row with the explanation in its
/// tooltip. Only a flip that needs the operator's eye — under
/// [MeridianFlipCountdownBanner.kWarningThreshold] or imminent — takes this
/// full-width banner above the canvas. The calm banner used to spend 85 px of
/// every armed night pushing the whole view down to say "no action needed".
///
/// The countdown model has no manual-flip or failed-flip state to surface
/// here: a failed flip is reported by the flip itself (the meridian-flip
/// progress dialog and notifications), not by this projection.
///
/// The flip is **always** performed automatically — by the Rust `meridian_flip`
/// trigger (an always-on watchdog) or, during a running sequence, by the
/// in-sequence flip node. This banner is therefore *status only*: it never
/// offers a manual-action button, which would contradict "automatic watchdog",
/// and it auto-hides whenever a flip is not armed. State comes from
/// [meridianCountdownProvider], a read-only projection; this widget never
/// mutates flip state.
///
/// The 15-second wall-clock tick lives in the widgets, not in the provider:
/// [_MeridianCountdownTicker] creates a [Timer.periodic] in `initState`,
/// cancels it in `dispose`, and invalidates the (timer-free) provider each
/// tick so the remaining-time readout counts down. Owning the timer in the
/// widget means it is cancelled synchronously when the tree is torn down, so
/// it cannot leak past disposal the way an autoDispose periodic stream does.
/// The chip and the banner each own one, so either keeps counting on its own.
class MeridianFlipCountdownBanner extends ConsumerStatefulWidget {
  const MeridianFlipCountdownBanner({super.key});

  /// HA-based countdown switches from the calm `info` tone to an attention
  /// `warning` tone once the flip is this close — late enough to stay quiet for
  /// most of the night, early enough that the operator notices before the mount
  /// starts moving.
  static const Duration kWarningThreshold = Duration(minutes: 10);

  /// How long the flip must stay disarmed before an operator dismissal is
  /// forgotten. A mount heartbeat flap disarms the countdown for tens of
  /// seconds at a time; resetting the dismissal immediately let the banner
  /// reappear on every auto-reconnect, so the reset waits out the flap.
  static const Duration kDismissalResetGrace = Duration(minutes: 5);

  @override
  ConsumerState<MeridianFlipCountdownBanner> createState() =>
      _MeridianFlipCountdownBannerState();
}

/// Re-reads [meridianCountdownProvider] on [kMeridianCountdownTick] so a
/// countdown ticks down even when no upstream input changes.
mixin _MeridianCountdownTicker<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(kMeridianCountdownTick, (_) {
      if (mounted) {
        ref.invalidate(meridianCountdownProvider);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

class _MeridianFlipCountdownBannerState
    extends ConsumerState<MeridianFlipCountdownBanner>
    with _MeridianCountdownTicker<MeridianFlipCountdownBanner> {
  /// Pending reset of the operator's dismissal, armed while the flip is
  /// disarmed. See [MeridianFlipCountdownBanner.kDismissalResetGrace].
  Timer? _disarmResetTimer;

  /// The last pier side the countdown actually reported. Compared against
  /// incoming states rather than the previous emission because a heartbeat
  /// flap can blank the field (mount state resets on disconnect): an
  /// east → (null while flapping) → west sequence is still a completed
  /// flip, not a same-cycle re-arm.
  String? _lastSeenPierSide;

  @override
  void dispose() {
    _disarmResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reset the operator's dismissal once the flip has stayed disarmed for
    // [MeridianFlipCountdownBanner.kDismissalResetGrace], so a fresh arm cycle
    // (a new night, or the next flip after this one completes) surfaces the
    // banner again — but a transient disconnect flap cannot un-dismiss it.
    ref.listen<MeridianCountdownState>(meridianCountdownProvider, (prev, next) {
      // The flip this countdown was for has happened: the mount now reports
      // the other pier side. A new cycle starts clean, grace or not.
      final side = next.sideOfPier;
      final pierSideChanged = side != null &&
          _lastSeenPierSide != null &&
          side != _lastSeenPierSide;
      if (side != null) _lastSeenPierSide = side;
      if (pierSideChanged) {
        _disarmResetTimer?.cancel();
        _disarmResetTimer = null;
        ref.read(meridianBannerDismissedSeverityProvider.notifier).state = null;
        return;
      }
      if (next.isArmed) {
        // Re-armed before the grace elapsed (e.g. auto-reconnect): the
        // dismissal stands.
        _disarmResetTimer?.cancel();
        _disarmResetTimer = null;
        return;
      }
      if (ref.read(meridianBannerDismissedSeverityProvider) != null &&
          _disarmResetTimer == null) {
        _disarmResetTimer = Timer(
          MeridianFlipCountdownBanner.kDismissalResetGrace,
          () {
            _disarmResetTimer = null;
            if (mounted) {
              ref.read(meridianBannerDismissedSeverityProvider.notifier).state =
                  null;
            }
          },
        );
      }
    });

    // The projection is synchronous and always present; when nothing is armed it
    // resolves to a not-armed state and [_MeridianFlipCountdownView] renders
    // nothing. The banner is ambient status, never a blocker.
    final state = ref.watch(meridianCountdownProvider);
    // Seed the pier-side memory with the value already in force at mount; the
    // listener above only sees CHANGES after this build. `??` keeps later
    // builds from clobbering the tracked value (the listener owns updates).
    _lastSeenPierSide ??= state.sideOfPier;
    final dismissedSeverityIndex =
        ref.watch(meridianBannerDismissedSeverityProvider);
    return _MeridianFlipCountdownView(
      state: state,
      dismissedSeverityIndex: dismissedSeverityIndex,
      onDismiss: (severityIndex) => ref
          .read(meridianBannerDismissedSeverityProvider.notifier)
          .state = severityIndex,
    );
  }
}

/// Stateless render of a resolved [MeridianCountdownState]. Split out so the
/// presentation logic is unit-testable in isolation and the [ConsumerWidget]
/// stays a thin provider adapter.
class _MeridianFlipCountdownView extends StatelessWidget {
  const _MeridianFlipCountdownView({
    required this.state,
    required this.dismissedSeverityIndex,
    required this.onDismiss,
  });

  final MeridianCountdownState state;

  /// The [SkotiqAlertSeverity.index] the operator last dismissed at, or
  /// `null` if not dismissed. The banner hides while the live severity is at or
  /// below this; an escalation above it re-surfaces the banner.
  final int? dismissedSeverityIndex;

  /// Invoked with the current severity index when the operator dismisses.
  final void Function(int severityIndex) onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final spec = _resolveSpec(state);

    // Not armed and nothing worth surfacing -> render nothing. This is the
    // common idle case (mount disconnected, flip disabled, parked, etc.); the
    // banner must not editorialize about a disabled feature. A calm countdown
    // is the toolbar chip's to show, not this banner's.
    if (spec == null || !spec.needsBanner) {
      return const SizedBox.shrink();
    }

    // Dismissed at this severity or a more urgent one: stay hidden until the
    // flip escalates beyond what was dismissed (so silencing the calm "in 5h"
    // status never swallows the attention-grade "imminent" banner).
    if (dismissedSeverityIndex != null &&
        spec.severity.index <= dismissedSeverityIndex!) {
      return const SizedBox.shrink();
    }

    final accent = switch (spec.severity) {
      SkotiqAlertSeverity.info => colors.info,
      SkotiqAlertSeverity.success => colors.success,
      SkotiqAlertSeverity.warning => colors.warning,
      SkotiqAlertSeverity.error => colors.error,
    };

    // Decoration recipe is identical to SkotiqAlert (severity tint @ 0.06
    // over surfaceAlt, border @ 0.35, radiusMd) so the banner is visually
    // indistinguishable from the design-system alert — we only compose a richer
    // body so the live countdown can use tabular telemetry figures. The two
    // alpha constants below are the exact values SkotiqAlert._getColors
    // uses; mirroring them keeps the banner on the same surface as every other
    // alert in the app.
    const alertTintAlpha = 0.06;
    const alertBorderAlpha = 0.35;
    final background = Color.alphaBlend(
      accent.withValues(alpha: alertTintAlpha),
      colors.surfaceAlt,
    );

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(
          color: accent.withValues(alpha: alertBorderAlpha),
        ),
      ),
      padding: SkotiqTokens.paddingLg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(spec.icon, size: SkotiqTokens.iconMd, color: accent),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                spec.title,
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  spec.subtitle,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textPrimary.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          if (spec.showPierChip && state.sideOfPier != null) ...[
            const SizedBox(width: SkotiqTokens.spaceMd),
            _PierSideChip(sideOfPier: state.sideOfPier!),
          ],
          const SizedBox(width: SkotiqTokens.spaceSm),
          // Dismiss the ambient status. This is NOT a manual flip action (the
          // flip stays fully automatic) — it only silences the banner, and an
          // escalation re-surfaces it.
          _DismissButton(
            color: colors.textMuted,
            onTap: () => onDismiss(spec.severity.index),
          ),
        ],
      ),
    );
  }
}

/// Compact close affordance for the ambient meridian-flip banner. A bordered
/// `InkResponse` rather than a full-padding [IconButton] so it reads as a quiet
/// "dismiss this status" control, not a primary action.
class _DismissButton extends StatelessWidget {
  const _DismissButton({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Dismiss',
      child: InkResponse(
        onTap: onTap,
        radius: SkotiqTokens.iconMd,
        containedInkWell: true,
        child: Padding(
          padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
          child:
              Icon(SkotiqIcons.close, size: SkotiqTokens.iconSm, color: color),
        ),
      ),
    );
  }
}

/// Resolved presentation for a given countdown state, or `null` to render
/// nothing. Pure function so the render rules are exhaustively testable.
_BannerSpec? _resolveSpec(MeridianCountdownState state) {
  // Not armed
  // Keep it quiet by default: a disabled/disconnected flip is not worth a
  // banner on the imaging tab. The honest explanation already lives in the
  // sequence editor's watchdog badge and the meridian-flip settings.
  if (!state.isArmed) {
    return null;
  }

  // Armed, tracking-limit method (no numeric countdown)
  // minutesBeforeLimit / onTrackingLimitHit decisions live entirely in the Rust
  // trigger evaluator. We must not fabricate a countdown; surface an honest
  // "monitored by the sequencer" info banner instead.
  if (state.timeToFlip == null) {
    return const _BannerSpec(
      severity: SkotiqAlertSeverity.info,
      icon: LucideIcons.flipHorizontal2,
      title: _BannerTitle(text: 'Meridian flip armed'),
      subtitle: 'Monitored by the sequencer — no action needed.',
      showPierChip: true,
    );
  }

  // Armed, flip imminent (countdown at or past zero)
  final remaining = state.timeToFlip!;
  if (remaining <= Duration.zero) {
    return _BannerSpec(
      severity: SkotiqAlertSeverity.warning,
      icon: LucideIcons.flipHorizontal2,
      title: const _BannerTitle(text: 'Meridian flip imminent'),
      subtitle: state.isSequencerOwned
          ? 'Handled automatically by the running sequence.'
          : 'Automatic — the meridian-flip watchdog is running it now. '
              'No action needed.',
      showPierChip: true,
    );
  }

  // Armed, live numeric countdown
  final isWarning = remaining < MeridianFlipCountdownBanner.kWarningThreshold;
  return _BannerSpec(
    severity:
        isWarning ? SkotiqAlertSeverity.warning : SkotiqAlertSeverity.info,
    icon: LucideIcons.flipHorizontal2,
    title: _BannerTitle(
      text: 'Meridian flip in ',
      // Tabular telemetry figures so the ticking countdown never shifts layout.
      trailing: formatTimeToFlip(remaining),
    ),
    subtitle: state.isSequencerOwned
        ? 'Handled automatically by the running sequence.'
        : 'Automatic — the meridian-flip watchdog will run this for you. No action needed.',
    showPierChip: true,
  );
}

/// The calm meridian-flip countdown, as a compact chip for the viewer toolbar:
/// "Flip in 3h 6m", or "Flip armed" when the flip is armed against a tracking
/// limit and has no countdown to show. The explanation the banner used to
/// spell out ("Automatic — the watchdog will run this for you") is in the
/// tooltip.
///
/// Renders nothing when no flip is armed, and nothing once the flip needs
/// attention: from [MeridianFlipCountdownBanner.kWarningThreshold] on, the
/// banner above the canvas carries it and two surfaces would say it twice.
class MeridianFlipChip extends ConsumerStatefulWidget {
  const MeridianFlipChip({super.key});

  @override
  ConsumerState<MeridianFlipChip> createState() => _MeridianFlipChipState();
}

class _MeridianFlipChipState extends ConsumerState<MeridianFlipChip>
    with _MeridianCountdownTicker<MeridianFlipChip> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(meridianCountdownProvider);
    final spec = _resolveSpec(state);
    if (spec == null || spec.needsBanner) return const SizedBox.shrink();

    final remaining = state.timeToFlip;
    final label = remaining == null
        ? 'Flip armed'
        : 'Flip in ${formatTimeToFlip(remaining)}';
    final side = state.sideOfPier;
    final explanation = <String>[
      spec.title.trailing == null
          ? spec.title.text
          : '${spec.title.text}${spec.title.trailing}',
      spec.subtitle,
      if (side != null && side.trim().isNotEmpty) 'Pier ${pierSideLabel(side)}',
    ].join('\n');

    return Padding(
      // The meta line's own segment gap, so the chip reads as its next part.
      padding: const EdgeInsets.only(left: SkotiqTokens.spaceMd),
      child: SkotiqTooltip(
        message: explanation,
        position: SkotiqTooltipPosition.bottom,
        maxWidth: 320,
        child: Semantics(
          container: true,
          label: explanation,
          excludeSemantics: true,
          child: SkotiqChip(
            label: label,
            icon: LucideIcons.flipHorizontal2,
          ),
        ),
      ),
    );
  }
}

/// Formats a countdown duration as a compact `H​h M​m` / `M​m` label.
///
/// Rounds *up* to whole minutes so the readout never claims less time than is
/// actually left — showing "2m" when 2m05s remain would be a small lie the
/// operator could act on. Because of the round-up, any strictly-positive
/// duration reads at least "1m"; a value at or below zero is handled by the
/// caller's "imminent" branch and reads "now".
///
/// Public + pure so the formatting is unit-tested directly.
String formatTimeToFlip(Duration remaining) {
  if (remaining <= Duration.zero) {
    return 'now';
  }
  // Round up to the next whole minute.
  final totalMinutes = (remaining.inSeconds + 59) ~/ 60;
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) {
    return '${minutes}m';
  }
  if (minutes == 0) {
    return '${hours}h';
  }
  return '${hours}h ${minutes}m';
}

/// Banner title: a leading label plus an optional tabular-figure value. The
/// value uses [SkotiqTypography.telemetryMd] (tabular) so the live countdown
/// ticks in place without nudging the rest of the row.
class _BannerTitle extends StatelessWidget {
  const _BannerTitle({required this.text, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final labelStyle =
        SkotiqTypography.label.copyWith(color: colors.textPrimary);

    if (trailing == null) {
      return Text(text, style: labelStyle);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(child: Text(text, style: labelStyle)),
        Text(
          trailing!,
          style: SkotiqTypography.telemetryMd.copyWith(
            color: colors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// Small trailing chip showing the mount-reported side of pier, hinting at flip
/// direction. Matches the `_InfoChip` styling from [MeridianFlipProgressDialog].
class _PierSideChip extends StatelessWidget {
  const _PierSideChip({required this.sideOfPier});

  final String sideOfPier;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(SkotiqIcons.move,
              size: SkotiqTokens.iconXs, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            'Pier ${pierSideLabel(sideOfPier)}',
            style:
                SkotiqTypography.labelSm.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Normalizes the driver-reported side-of-pier string to a clean, capitalized
/// label. Unknown / unexpected values pass through verbatim rather than being
/// silently dropped — the operator should see exactly what the mount reports.
String pierSideLabel(String raw) {
  final v = raw.trim();
  switch (v.toLowerCase()) {
    case 'east':
    case 'pierside_east':
      return 'East';
    case 'west':
    case 'pierside_west':
      return 'West';
    default:
      return v.isEmpty ? 'Unknown' : v;
  }
}

/// Internal presentation descriptor produced by [_resolveSpec].
class _BannerSpec {
  const _BannerSpec({
    required this.severity,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.showPierChip,
  });

  final SkotiqAlertSeverity severity;
  final IconData icon;
  final _BannerTitle title;
  final String subtitle;
  final bool showPierChip;

  /// Whether this state earns the full-width banner. Everything calmer than a
  /// warning is ambient status and rides in the toolbar chip instead.
  bool get needsBanner => severity != SkotiqAlertSeverity.info;
}
