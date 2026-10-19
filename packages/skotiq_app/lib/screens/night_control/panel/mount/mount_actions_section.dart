// The Mount section: Home, Flip now, Unpark, Park, Limits… and a line that
// states the meridian-flip settings in force.
//
// Park is the only control on Tonight that parks the mount, and only after
// the operator confirms it in a dialog. Nothing here parks on its own.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../models/command_action_result.dart';
import '../../../../services/mount_command_service.dart';
import '../../../../utils/confirm_dialog.dart';
import '../../actions/manual_action_gating.dart';
import '../../actions/night_action_controller.dart';
import '../../night_control_contracts.dart';
import 'night_mount_tab.dart';
import 'night_panel_parts.dart';

/// Where Limits… goes: the sequencer settings, which hold the meridian flip.
const String kNightMountLimitsRoute = '/settings?section=sequencer';

class NightMountActionsSection extends ConsumerStatefulWidget {
  const NightMountActionsSection({super.key});

  @override
  ConsumerState<NightMountActionsSection> createState() =>
      _NightMountActionsSectionState();
}

class _NightMountActionsSectionState
    extends ConsumerState<NightMountActionsSection> {
  /// The command in flight ('home', 'park', 'unpark').
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final facts = watchNightMountFacts(ref);
    final mount = facts.mount;
    final caps = facts.capabilities;
    final busy = _busy != null ? l10n.text('nightScopeWhyCommandBusy') : null;

    String? homeReason = facts.baseReason(l10n) ?? busy;
    if (homeReason == null) {
      if (!caps!.canFindHome) {
        homeReason = l10n.text('nightScopeWhyNoHome');
      } else if (mount.isHoming) {
        homeReason = l10n.text('nightScopeWhyHoming');
      } else if (mount.isSlewing) {
        homeReason = l10n.text('nightScopeWhySlewing');
      }
    }

    // A parked mount needs no run check to unpark: unparking never moves it.
    String? unparkReason =
        facts.baseReason(l10n, allowParked: true, allowDuringRun: true) ?? busy;
    if (unparkReason == null) {
      if (!mount.isParked) {
        unparkReason = l10n.text('nightScopeWhyNotParked');
      } else if (!caps!.canUnpark) {
        unparkReason = l10n.text('nightScopeWhyMountCannot');
      }
    }

    // Park stays available during a run: it is the operator's own call, and
    // the confirmation says what it does to the run.
    String? parkReason = facts.baseReason(l10n, allowDuringRun: true) ?? busy;
    if (parkReason == null && !caps!.canPark) {
      parkReason = l10n.text('nightScopeWhyMountCannot');
    }

    // P9: an in-run "request flip now" (native N2) enables Flip during a run.
    final flipReason =
        manualActionDisabledReason(facts.inputs, ManualActionId.flip)
            ?.resolve(l10n);
    final flipInFlight = facts.inputs.action.isBusy &&
        facts.inputs.action.active == ManualActionId.flip;

    return NightPanelSection(
      title: l10n.text('nightScopeMount'),
      trailing: facts.connected ? mount.deviceName : null,
      children: [
        NightPanelButtonGrid(
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.home'),
              label: l10n.text('nightScopeHome'),
              busy: _busy == 'home' || mount.isHoming,
              tooltip: l10n.text('nightScopeHomeCaution'),
              disabledReason: homeReason,
              onPressed: homeReason == null
                  ? () => _run(
                        'home',
                        () => ref.read(mountCommandServiceProvider).findHome(),
                      )
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.flip'),
              label: l10n.text('nightActFlip'),
              busy: flipInFlight,
              disabledReason: flipReason,
              onPressed: flipReason == null
                  ? () => unawaited(ref.read(nightActionApiProvider).flipNow())
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.unpark'),
              label: l10n.text('nightScopeUnpark'),
              busy: _busy == 'unpark',
              disabledReason: unparkReason,
              onPressed: unparkReason == null
                  ? () => _run(
                        'unpark',
                        () => ref.read(mountCommandServiceProvider).unpark(),
                      )
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.park'),
              label: l10n.text('nightScopePark'),
              busy: _busy == 'park',
              disabledReason: parkReason,
              onPressed: parkReason == null
                  ? () => unawaited(_confirmPark(facts.runActive))
                  : null,
            ),
            // P9: "Set park" joins this row once the bridge has
            // mount_set_park (native N1); until then it is left out.
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.limits'),
              label: l10n.text('nightScopeLimits'),
              onPressed: () => context.go(kNightMountLimitsRoute),
            ),
          ],
        ),
        const _FlipSettingsLine(),
      ],
    );
  }

  /// Parks only after the operator confirms in a dialog.
  Future<void> _confirmPark(bool runActive) async {
    final l10n = context.l10n;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: l10n.text('nightScopeParkTitle'),
      message: l10n.text(
        runActive ? 'nightScopeParkBodyRun' : 'nightScopeParkBody',
      ),
      confirmLabel: l10n.text('nightScopePark'),
      cancelLabel: l10n.text('cancel'),
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run('park', () => ref.read(mountCommandServiceProvider).park());
  }

  Future<void> _run(
    String id,
    Future<CommandActionResult> Function() command,
  ) async {
    setState(() => _busy = id);
    try {
      final result = await command();
      if (mounted) showNightCommandResult(context, result);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}

/// "Flips 5 min past the meridian · recenters after · settles 10 s".
class _FlipSettingsLine extends ConsumerWidget {
  const _FlipSettingsLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final enabled = ref.watch(isMeridianFlipEnabledProvider);
    if (!enabled) return NightPanelNote(l10n.text('nightScopeFlipOff'));
    final settings = ref.watch(effectiveMeridianFlipSettingsProvider);
    return NightPanelNote(nightFlipSettingsText(l10n, settings));
  }
}

/// The flip settings in force, in one line.
String nightFlipSettingsText(
  SkotiqLocalizations l10n,
  MeridianFlipSettings settings,
) {
  String number(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
  final trigger = switch (settings.triggerMethod) {
    MeridianTriggerMethod.minutesPastMeridian => l10n.text(
        'nightScopeFlipPast',
        params: {'minutes': number(settings.minutesPastMeridian)},
      ),
    MeridianTriggerMethod.hourAngleThreshold => l10n.text(
        'nightScopeFlipHourAngle',
        params: {'hours': number(settings.hourAngleThreshold)},
      ),
    MeridianTriggerMethod.minutesBeforeLimit => l10n.text(
        'nightScopeFlipBeforeLimit',
        params: {'minutes': number(settings.minutesBeforeLimit)},
      ),
    MeridianTriggerMethod.onTrackingLimitHit =>
      l10n.text('nightScopeFlipAtLimit'),
  };
  return [
    trigger,
    if (settings.recenterAfterFlip) l10n.text('nightScopeFlipRecenter'),
    l10n.text(
      'nightScopeFlipSettle',
      params: {'seconds': number(settings.settleTimeSeconds)},
    ),
  ].join(' · ');
}
