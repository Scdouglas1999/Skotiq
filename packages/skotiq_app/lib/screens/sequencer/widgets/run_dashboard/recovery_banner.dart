/// Recovery Mode — visible Run Dashboard banner + status LED.
///
/// When the executor enters `Recovering`, this banner pins to the top of
/// the Run Dashboard (above [RunDashboardCriticalBanner]) and surfaces:
///   * cause description (humanised)
///   * attempt counter ("Attempt 2 of 9")
///   * countdown until the next auto-retry
///   * "Try Now" button (forces an immediate retry)
///   * "Skip Node" button (skips the currently failing node and continues)
///   * "Abort" button, hold-to-confirm (exits the loop, marks Failed)
///
/// Reuses the design-system colour tokens from [SkotiqColors] so the
/// red palette matches the existing critical-event banner.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import 'sequence_status_visuals.dart';

/// Persistent banner that renders the in-flight recovery context. Returns
/// an empty widget when [currentRecoveryProvider] is `null`.
///
/// Auto-rebuilds every 500ms while the recovery is in the `Waiting`
/// phase so the countdown stays smooth without the executor needing to
/// emit ProgressUpdated events for the timer alone.
class RunDashboardRecoveryBanner extends ConsumerStatefulWidget {
  const RunDashboardRecoveryBanner({super.key});

  @override
  ConsumerState<RunDashboardRecoveryBanner> createState() =>
      _RunDashboardRecoveryBannerState();
}

class _RunDashboardRecoveryBannerState
    extends ConsumerState<RunDashboardRecoveryBanner>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      // Rebuild every 500ms so the countdown ticks smoothly. We don't
      // store this as state — we just trigger a setState to re-read
      // `nextAttemptInSecs(now)`. The timer is cheap (no setState body)
      // because it's only re-evaluating an in-memory DateTime delta.
      if ((d - _elapsed).inMilliseconds < 500) return;
      _elapsed = d;
      if (mounted) setState(() {});
    });
    // Don't start here — the ticker is driven from build() so it only runs
    // while a recovery is actively counting down (see _syncTicker).
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Start/stop the countdown ticker to match whether a recovery is
  /// actively waiting for its next retry. Mirrors the `_syncPulse` pattern
  /// in `sequence_progress_bar.dart` so the 500ms rebuild loop is idle when
  /// there is nothing to count down (no recovery, or recovery attempting /
  /// recovered / gave-up).
  void _syncTicker({required bool needsCountdown}) {
    if (needsCountdown) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) {
        _ticker.stop();
        _elapsed = Duration.zero;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The bridge feeds currentRecoveryProvider from the executor's recovery
    // events and only runs while something watches it. The banner is where
    // the state is shown, so the banner keeps it running; nothing else in the
    // app did, and a recovery (a weather hold included) never appeared.
    ref.watch(recoveryEventBridgeProvider);
    final ctx = ref.watch(currentRecoveryProvider);
    // Only run the countdown ticker while a recovery is waiting for its next
    // retry; otherwise the 500ms setState loop runs for nothing.
    _syncTicker(needsCountdown: ctx != null && ctx.isWaiting);
    if (ctx == null) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    // Watch (not read) so the buttons always hold the current control if the
    // recovery control provider is ever re-created (e.g. a backend swap).
    final control = ref.watch(recoveryControlProvider);
    final now = DateTime.now().toUtc();
    final nextAttemptSecs = ctx.nextAttemptInSecs(now);
    final remainingBudgetSecs =
        ctx.remainingSecs(now).clamp(0.0, double.infinity);
    // A weather hold is waiting, not repairing: it has no attempt budget,
    // the mount keeps tracking, and the run resumes by itself.
    final weatherHold = ctx.cause.kind == 'WeatherUnsafe';
    final tone = weatherHold ? colors.warning : colors.error;
    final heldSecs = now.difference(ctx.startedAt).inSeconds.toDouble();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.20),
        border: Border(
          top: BorderSide(color: tone, width: 1.8),
          bottom: BorderSide(color: tone.withValues(alpha: 0.7)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.space2xl,
          vertical: SkotiqTokens.spaceMd,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final buttons = _RecoveryActionButtons(
              colors: colors,
              control: control,
              onSkyClear: weatherHold
                  ? () => ref.read(weatherSafetyProvider.notifier).snooze(
                        const Duration(minutes: 30),
                        reason: 'Operator on the recovery banner: the sky is '
                            'clear',
                      )
                  : null,
            );
            final summary = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                StatusDot(
                    color: tone,
                    size: 12,
                    variant: weatherHold
                        ? StatusDotVariant.static
                        : StatusDotVariant.urgent),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            weatherHold
                                ? l10n.text('recoveryWeatherTag')
                                : 'RECOVERING',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize10,
                              fontWeight: FontWeight.w800,
                              color: tone,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              weatherHold
                                  ? l10n.text('recoveryWeatherTitle')
                                  : ctx.cause.displayLabel,
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize14,
                                fontWeight: FontWeight.w700,
                                color: colors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        weatherHold
                            ? l10n.text(
                                'recoveryWeatherStatus',
                                params: {'held': _formatSecs(heldSecs)},
                              )
                            : _statusLine(
                                ctx, nextAttemptSecs, remainingBudgetSecs),
                        style: SkotiqTypography.withTabular(
                          SkotiqTypography.labelSm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      if (ctx.lastError != null &&
                          ctx.lastError!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          weatherHold
                              ? ctx.lastError!
                              : 'Last error: ${ctx.lastError}',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textMuted,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
            // Narrow: the buttons go under the text instead of squeezing it.
            if (constraints.maxWidth < _stackButtonsBelowWidth) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: buttons,
                    ),
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: summary),
                const SizedBox(width: SkotiqTokens.spaceMd),
                buttons,
              ],
            );
          },
        ),
      ),
    );
  }

  /// Below this width the action buttons sit under the banner text.
  static const double _stackButtonsBelowWidth = 900;

  String _statusLine(
      RecoveryStatus ctx, double nextAttemptSecs, double remainingBudgetSecs) {
    final attempts = 'Attempt ${ctx.attemptCount} of ${ctx.maxAttempts}';
    if (ctx.isAttempting) {
      return '$attempts · attempting now…';
    }
    if (ctx.isWaiting) {
      if (nextAttemptSecs <= 1.0) {
        return '$attempts · next attempt firing now';
      }
      return '$attempts · next retry in ${_formatSecs(nextAttemptSecs)}'
          ' · budget left ${_formatSecs(remainingBudgetSecs)}';
    }
    if (ctx.isRecovered) {
      return '$attempts · recovered — resuming sequence';
    }
    if (ctx.isGaveUp) {
      return '$attempts · loop ended';
    }
    return attempts;
  }

  String _formatSecs(double s) {
    if (s < 60) {
      return '${s.round()}s';
    }
    final mins = (s / 60).floor();
    final secs = (s - mins * 60).round();
    return secs == 0 ? '${mins}m' : '${mins}m ${secs}s';
  }
}

/// Trio of recovery-mode buttons: Try Now, Skip Node, Abort.
///
/// Shared with the companion mobile [SequencerTab] so recovery actions are
/// available there too. Each button tracks its OWN in-flight state, so a busy
/// "Abort" hold-and-release does not freeze the "Try Now" spinner.
///
/// Abort is wrapped in [HoldToConfirmButton] (1500 ms hold) so a stray click
/// cannot kill a multi-hour overnight run. Errors thrown by the underlying
/// [RecoveryControl] surface through a [ScaffoldMessenger] SnackBar: swallowed,
/// they leave the operator believing recovery was actioned.
class _RecoveryActionButtons extends StatefulWidget {
  final SkotiqColors colors;
  final RecoveryControl control;

  const _RecoveryActionButtons({
    required this.colors,
    required this.control,
    this.onSkyClear,
  });

  /// Set for a weather hold: the operator says the sky is clear, the
  /// weather verdict is set aside for 30 minutes and the run resumes now.
  /// A weather hold has no node to skip, so Skip node is not offered.
  final VoidCallback? onSkyClear;

  @override
  State<_RecoveryActionButtons> createState() => _RecoveryActionButtonsState();
}

class _RecoveryActionButtonsState extends State<_RecoveryActionButtons> {
  bool _tryNowBusy = false;
  bool _skipBusy = false;
  bool _abortBusy = false;

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _tryNow() async {
    if (_tryNowBusy) return;
    setState(() => _tryNowBusy = true);
    try {
      await widget.control.tryNow();
    } catch (e) {
      _showError(extractRecoveryActionError('Retry failed', e));
    } finally {
      if (mounted) setState(() => _tryNowBusy = false);
    }
  }

  Future<void> _skipNode() async {
    if (_skipBusy) return;
    setState(() => _skipBusy = true);
    try {
      await widget.control.skipNode();
    } catch (e) {
      _showError(extractRecoveryActionError('Skip failed', e));
    } finally {
      if (mounted) setState(() => _skipBusy = false);
    }
  }

  Future<void> _abort() async {
    if (_abortBusy) return;
    setState(() => _abortBusy = true);
    try {
      await widget.control.abort();
    } catch (e) {
      _showError(extractRecoveryActionError('Abort failed', e));
    } finally {
      if (mounted) setState(() => _abortBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSkyClear = widget.onSkyClear;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onSkyClear != null) ...[
          SkotiqButton(
            key: const Key('recovery_sky_clear'),
            label: context.l10n.text('nightWeatherSkyClear'),
            icon: LucideIcons.sun,
            size: ButtonSize.small,
            onPressed: onSkyClear,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        SkotiqButton(
          key: const Key('recovery_try_now'),
          label: onSkyClear != null
              ? context.l10n.text('recoveryWeatherCheckNow')
              : 'Try now',
          icon: LucideIcons.rotateCw,
          size: ButtonSize.small,
          isLoading: _tryNowBusy,
          onPressed: _tryNowBusy ? null : _tryNow,
        ),
        if (onSkyClear == null) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            key: const Key('recovery_skip_node'),
            label: 'Skip node',
            icon: LucideIcons.skipForward,
            size: ButtonSize.small,
            variant: ButtonVariant.outline,
            isLoading: _skipBusy,
            onPressed: _skipBusy ? null : _skipNode,
          ),
        ],
        const SizedBox(width: SkotiqTokens.spaceSm),
        // Abort exits the recovery loop and marks the sequence Failed —
        // an unrecoverable user decision. Wrap in [HoldToConfirmButton]
        // so a stray click on a phone, trackpad, or accidental keyboard
        // activation can't kill an overnight run. The inner button stays
        // keyed `recovery_abort` for backward-compat with widget tests;
        // tests targeting the destructive path now drive a long-press.
        HoldToConfirmButton(
          key: const Key('recovery_abort_hold'),
          enabled: !_abortBusy,
          holdColor: widget.colors.error,
          confirmText: 'Hold to abort',
          semanticsLabel: 'Press and hold to abort recovery',
          onConfirmed: _abort,
          child: IgnorePointer(
            child: SkotiqButton(
              key: const Key('recovery_abort'),
              label: 'Abort',
              icon: LucideIcons.xOctagon,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              isLoading: _abortBusy,
              onPressed: _abort,
            ),
          ),
        ),
      ],
    );
  }
}

/// Best-effort error formatter for the recovery action buttons.
///
/// [SkotiqError] from the network backend carries a userMessage that
/// is already operator-friendly; anything else falls back to the raw
/// `toString()` after stripping the `Exception:` prefix common to
/// Dart `Exception` subclasses.
String extractRecoveryActionError(String prefix, Object error) {
  if (error is SkotiqError) {
    return '$prefix: ${error.userMessage}';
  }
  final raw = error.toString();
  final cleaned =
      raw.startsWith('Exception: ') ? raw.substring('Exception: '.length) : raw;
  return '$prefix: $cleaned';
}

/// Status-LED widget used by the sequencer screen's top bar and the
/// dashboard header. Reads [sequenceProgressProvider] for the canonical
/// state and renders a small dot with a colour that matches the state.
/// Recovering pulses red; Failed is solid red; Paused is orange; Running
/// is green; Idle is grey.
class SequencerStatusLed extends ConsumerWidget {
  final double size;
  final bool showLabel;

  const SequencerStatusLed({
    super.key,
    this.size = 10.0,
    this.showLabel = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(sequenceProgressProvider);
    final colors = SkotiqColors.of(context);
    final state = progress.state;

    // Single source of truth for color/label/variant so the LED can never
    // diverge from the toolbar/mobile status badges.
    final visuals = SequenceStatusVisuals.of(state, colors, context.l10n);
    final color = visuals.color;
    final label = visuals.label;
    final variant = visuals.variant;

    final dot = StatusDot(color: color, size: size, variant: variant);

    if (!showLabel) return dot;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            fontWeight: FontWeight.w700,
            color: colors.textSecondary,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}
