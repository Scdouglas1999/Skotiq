// The hero line — the second signature moment (02) and the ONE place Tonight
// puts its primary action (06 §Tonight).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../services/sequence_action_service.dart';
import '../../../../utils/snackbar_helper.dart';
import '../../../sequencer/sequence_counts.dart';
import '../../../sequencer/widgets/preflight_validation_dialog.dart';
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'tonight_night.dart';

/// Which of the four hero faces is showing.
///
/// The eyebrow, the display line and the pair of buttons all switch together;
/// splitting the decision across three widgets is how the old dashboard came to
/// offer "Start" beside a "Stopping…" badge.
enum TonightHeroState { running, paused, sequenceReady, nothingRunning }

/// The hero's state, derived from the executor and the loaded sequence.
final tonightHeroStateProvider = Provider<TonightHeroState>((ref) {
  final execution = ref.watch(sequenceExecutionStateProvider);
  if (execution == SequenceExecutionState.paused) {
    return TonightHeroState.paused;
  }
  if (execution != SequenceExecutionState.idle &&
      execution != SequenceExecutionState.completed &&
      execution != SequenceExecutionState.failed) {
    return TonightHeroState.running;
  }
  final sequence = ref.watch(currentSequenceProvider);
  final launchable = sequence != null &&
      (sequence.targetHeaders.isNotEmpty || sequence.totalExposures > 0);
  return launchable
      ? TonightHeroState.sequenceReady
      : TonightHeroState.nothingRunning;
});

/// Whether any of the four core devices is online.
///
/// Drives the one place the hero's primary would otherwise lie; the same four
/// devices `dashboardStandbyProvider` consults.
final anyCoreDeviceConnectedProvider = Provider<bool>((ref) {
  bool up(ProviderListenable<DeviceConnectionState> state) =>
      ref.watch(state) == DeviceConnectionState.connected;
  return up(cameraStateProvider.select((s) => s.connectionState)) ||
      up(mountStateProvider.select((s) => s.connectionState)) ||
      up(guiderStateProvider.select((s) => s.connectionState)) ||
      up(focuserStateProvider.select((s) => s.connectionState));
});

/// State eyebrow, the night's headline, one line of facts, and the ONE primary
/// action for the state.
class TonightHero extends ConsumerWidget {
  const TonightHero({super.key});

  /// The gap between the headline block and the buttons.
  static const double _ctaGap = SkotiqTokens.space2xl;

  /// The gap between adjacent facts on the facts line.
  static const double _factGap = 14;

  /// Below this the buttons drop under the headline instead of beside it.
  static const double _stackedWidth = 900;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final state = ref.watch(tonightHeroStateProvider);

    final headline = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _Eyebrow(state: state),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _Headline(state: state),
        const SizedBox(height: SkotiqTokens.spaceXs),
        _Facts(state: state, colors: colors, gap: _factGap),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final actions = _HeroActions(state: state);
        if (constraints.maxWidth < _stackedWidth) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              headline,
              const SizedBox(height: SkotiqTokens.spaceMd),
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(child: headline),
            const SizedBox(width: _ctaGap),
            actions,
          ],
        );
      },
    );
  }
}

/// `● SEQUENCE READY`, `● RUNNING · 42%`, `● PAUSED`, `● NOTHING RUNNING`.
class _Eyebrow extends ConsumerWidget {
  const _Eyebrow({required this.state});

  final TonightHeroState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    final (String label, Color dot, bool live) = switch (state) {
      TonightHeroState.running => (
          '${l10n.text('tnStateRunning')} · '
              '${(ref.watch(sequenceProgressProvider).progressPercent * 100).round()}%',
          colors.success,
          true,
        ),
      TonightHeroState.paused => (
          l10n.text('tnStatePaused'),
          colors.warning,
          false,
        ),
      TonightHeroState.sequenceReady => (
          l10n.text('tnStateSequenceReady'),
          colors.primary,
          false,
        ),
      TonightHeroState.nothingRunning => (
          l10n.text('tnStateNothingRunning'),
          colors.textMuted,
          false,
        ),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        StatusDot(color: dot, live: live),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          label.toUpperCase(),
          style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// The target, or the night's headline when nothing is loaded.
class _Headline extends ConsumerWidget {
  const _Headline({required this.state});

  final TonightHeroState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final target = ref.watch(runDashboardActiveTargetProvider);

    if (target != null) {
      final (name, alias) = _splitAlias(target.displayName);
      return Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: name),
            if (alias != null)
              TextSpan(
                text: ' · $alias',
                // The common name is the quiet half of the hero line: same
                // `display` metrics, weight 400 (02 "weight contrast instead
                // of size contrast").
                style: SkotiqTypography.display.copyWith(
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
        style: SkotiqTypography.display.copyWith(color: colors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final night = ref.watch(tonightNightProvider);
    final l10n = context.l10n;
    final headline = night == null
        ? l10n.text('tnHeadlineNoSite')
        : l10n.text(
            'tnHeadlineClearAfter',
            params: {'time': tonightClock(night.astroDark)},
          );

    return Text(
      headline,
      style: SkotiqTypography.display.copyWith(color: colors.textPrimary),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// `M51 (Whirlpool Galaxy)` → `('M51', 'Whirlpool Galaxy')`.
  ///
  /// Only splits a parenthesised alias the catalogue itself supplied; a plain
  /// name is left whole rather than guessed at.
  static (String, String?) _splitAlias(String displayName) {
    final open = displayName.indexOf(' (');
    if (open <= 0 || !displayName.endsWith(')')) return (displayName, null);
    final alias = displayName.substring(open + 2, displayName.length - 1);
    if (alias.isEmpty) return (displayName, null);
    return (displayName.substring(0, open), alias);
  }
}

/// One 14 px line of facts, 14 px apart: what is loaded · when it gets dark ·
/// the moon.
class _Facts extends ConsumerWidget {
  const _Facts({required this.state, required this.colors, required this.gap});

  final TonightHeroState state;
  final SkotiqColors colors;
  final double gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final night = ref.watch(tonightNightProvider);
    final facts = <String>[];

    final sequence = ref.watch(currentSequenceProvider);
    if (sequence != null && sequence.nodes.isNotEmpty) {
      final estimator = SequenceTimeEstimator(
        overhead: ref.watch(sequencerOverheadConfigProvider),
      );
      final total = estimator.estimateTotalDuration(sequence, DateTime.now());
      // The SAME count the Sequencer's own header chip prints. `nodes.length`
      // includes the invisible root, so the hero said 28 where the Sequencer
      // said 27 for one sequence — two surfaces contradicting each other about
      // a number the operator can see on both.
      final nodes = l10n.text(
        'tnNodeCount',
        params: {'count': '${visibleInstructionCount(sequence)}'},
      );
      facts.add(
        '${sequence.name} · $nodes · ~${tonightDuration(total) ?? '—'}',
      );
    } else {
      final site = ref.watch(appObserverLocationProvider);
      if (site != null) facts.add(_site(site));
    }

    if (night != null) {
      final until = night.untilDark;
      facts.add(
        until != null
            ? l10n.text(
                'tnDarkIn',
                params: {'duration': tonightDuration(until) ?? '—'},
              )
            : l10n.text(
                'tnDarkWindow',
                params: {
                  'start': tonightClock(night.astroDark),
                  'end': tonightClock(night.astroDawn),
                  'duration': tonightDuration(night.darkDuration) ?? '—',
                },
              ),
      );

      final percent = night.moonIlluminationRounded;
      final moonSet = night.moonSet;
      if (percent != null) {
        facts.add(
          moonSet != null
              ? l10n.text(
                  'tnMoonSets',
                  params: {
                    'percent': '$percent',
                    'time': tonightClock(moonSet),
                  },
                )
              : l10n.text('tnMoonOnly', params: {'percent': '$percent'}),
        );
      }
    }

    if (facts.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: gap,
      runSpacing: SkotiqTokens.spaceXs,
      children: <Widget>[
        for (final fact in facts)
          Text(
            fact,
            style: SkotiqTypography.body.copyWith(
              color: colors.textSecondary,
            ),
          ),
      ],
    );
  }

  /// `42.36° N, 71.06° W`.
  ///
  /// The mockup prefixes a place name ("Boston · …"); Skotiq stores no site
  /// NAME — [LocationSettings] is latitude / longitude / elevation — so the
  /// coordinates stand alone rather than being invented (noted in notes.md).
  static String _site(LocationSettings site) {
    final lat = site.latitude;
    final lon = site.longitude;
    return '${lat.abs().toStringAsFixed(2)}° ${lat >= 0 ? 'N' : 'S'}, '
        '${lon.abs().toStringAsFixed(2)}° ${lon >= 0 ? 'E' : 'W'}';
  }
}

/// The ONE primary action for the state, plus one secondary (05 §6, 02 rule 4).
class _HeroActions extends ConsumerWidget {
  const _HeroActions({required this.state});

  final TonightHeroState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    switch (state) {
      case TonightHeroState.running:
      case TonightHeroState.paused:
        return _RunActions(state: state, colors: colors);

      case TonightHeroState.sequenceReady:
        // Start is gated on a backend that can actually carry the command: a
        // remote controller whose host has gone away must not offer to launch
        // a night it cannot start.
        final canCommand = ref.watch(backendCanCommandProvider);
        return _ActionRow(
          children: <Widget>[
            SkotiqButton(
              label: l10n.text('tnOpenInSequencer'),
              icon: LucideIcons.listOrdered,
              variant: ButtonVariant.secondary,
              onPressed: () => context.go('/sequencer'),
            ),
            SkotiqButton(
              label: l10n.text('tnStartSequence'),
              icon: LucideIcons.play,
              variant: ButtonVariant.start,
              size: ButtonSize.large,
              onPressed: canCommand ? () => _start(context, ref) : null,
            ),
          ],
        );

      case TonightHeroState.nothingRunning:
        // 06 names "Connect equipment" as this state's primary, which is only
        // true while nothing IS connected. Offering it to an operator whose
        // camera and mount are already online is the app stating something
        // untrue, so a connected rig with nothing loaded is sent to the
        // Sequencer instead. Same state, same slot, honest verb.
        final connected = ref.watch(anyCoreDeviceConnectedProvider);
        return _ActionRow(
          children: <Widget>[
            SkotiqButton(
              label: l10n.text('tnPlanTarget'),
              icon: LucideIcons.compass,
              variant: ButtonVariant.secondary,
              onPressed: () => context.go('/planner'),
            ),
            if (connected)
              SkotiqButton(
                label: l10n.text('tnBuildSequence'),
                icon: LucideIcons.listOrdered,
                variant: ButtonVariant.primary,
                size: ButtonSize.large,
                onPressed: () => context.go('/sequencer'),
              )
            else
              SkotiqButton(
                label: l10n.text('tnConnectEquipment'),
                icon: LucideIcons.plug,
                variant: ButtonVariant.primary,
                size: ButtonSize.large,
                onPressed: () => context.go('/equipment'),
              ),
          ],
        );
    }
  }

  /// Route through the same pre-flight gate the Sequencer's Start uses so the
  /// hero cannot skip the safety checks.
  static Future<void> _start(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (_) => PreFlightValidationDialog(
        onStartSequence: () async {
          final result = await ref.read(sequenceActionServiceProvider).start();
          if (!context.mounted) return;
          context.showCommandActionResult(result);
        },
      ),
    );
  }
}

/// Stop + Pause / Resume while a run is live.
class _RunActions extends ConsumerWidget {
  const _RunActions({required this.state, required this.colors});

  final TonightHeroState state;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final execution = ref.watch(sequenceExecutionStateProvider);
    final running = state == TonightHeroState.running;

    Future<void> pauseOrResume() async {
      final service = ref.read(sequenceActionServiceProvider);
      final result = running ? await service.pause() : await service.resume();
      if (!context.mounted) return;
      context.showCommandActionResult(result);
    }

    Future<void> stop() async {
      final result = await ref.read(sequenceActionServiceProvider).stop();
      if (!context.mounted) return;
      context.showCommandActionResult(result);
    }

    final pauseButton = SkotiqButton(
      label: running ? l10n.text('tnPause') : l10n.text('tnResume'),
      icon: running ? LucideIcons.pause : LucideIcons.play,
      variant: running ? ButtonVariant.secondary : ButtonVariant.primary,
      size: running ? ButtonSize.medium : ButtonSize.large,
      onPressed: pauseOrResume,
    );

    // Stop stays hold-to-confirm: a stray click must not abort an overnight
    // run. The inner button is IgnorePointer so the hold gesture is owned
    // exclusively by HoldToConfirmButton.
    final stopButton = HoldToConfirmButton(
      enabled: execution.canStop,
      holdColor: colors.error,
      confirmText: l10n.text('tnHoldToStop'),
      semanticsLabel: l10n.text('tnHoldToStopHint'),
      onConfirmed: stop,
      child: IgnorePointer(
        child: SkotiqButton(
          label: l10n.text('tnStop'),
          icon: LucideIcons.square,
          variant: ButtonVariant.destructive,
          size: ButtonSize.large,
          onPressed: execution.canStop ? stop : null,
        ),
      ),
    );

    return _ActionRow(
      children: running
          ? <Widget>[pauseButton, stopButton]
          : <Widget>[stopButton, pauseButton],
    );
  }
}

/// The hero's pair of actions.
///
/// A `Wrap`, not a `Row`: at a phone width two buttons do not fit side by side,
/// and a `Row(mainAxisSize: min)` there overflows by ~240 px rather than
/// reflowing. `alignment: end` keeps the pair right-aligned beside the headline
/// on a wide page and left-aligned under it once the hero has stacked.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
