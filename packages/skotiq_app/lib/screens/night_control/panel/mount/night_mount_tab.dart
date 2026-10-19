// The right panel's Mount tab (board TonightMount): where the mount points,
// tracking rates, the move pad, Go to, and the mount's own actions.
//
// Nothing on this tab moves the mount on its own. Park asks first, and
// while a run is loaded the run owns pointing and tracking, so those
// controls say so instead of acting.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../models/command_action_result.dart';
import '../../../../services/mount_command_service.dart';
import '../../../../utils/snackbar_helper.dart';
import '../../actions/manual_action_gating.dart';
import '../../actions/night_action_controller.dart';
import '../../data/plan/night_plan_inputs.dart';
import 'mount_actions_section.dart';
import 'mount_go_to.dart';
import 'mount_move_pad.dart';
import 'night_panel_parts.dart';

/// What every Mount-tab control gates on, read once per build.
@immutable
class NightMountFacts {
  const NightMountFacts({
    required this.mount,
    required this.inputs,
    required this.capabilities,
    required this.capabilitiesLoading,
  });

  final MountState mount;
  final NightActionInputs inputs;

  /// Null while loading, or when the driver did not report them.
  final MountCapabilities? capabilities;
  final bool capabilitiesLoading;

  bool get connected =>
      mount.connectionState == DeviceConnectionState.connected &&
      mount.deviceId != null;

  bool get runActive => inputs.runActive;

  /// The first reason any mount command is refused, or null.
  ///
  /// [allowParked] for Unpark and the commands that work on a parked mount;
  /// [allowDuringRun] for the ones a loaded run does not own.
  String? baseReason(
    SkotiqLocalizations l10n, {
    bool allowParked = false,
    bool allowDuringRun = false,
  }) {
    if (!inputs.canCommand) return l10n.text('nightActWhyNoHost');
    if (!connected) return l10n.text('nightActWhyNoMount');
    if (!allowDuringRun && runActive) return l10n.text('nightActWhyRunOwns');
    final action = inputs.action;
    if (action.isBusy) {
      final active = action.active;
      return l10n.text(
        active == null
            ? 'nightActWhyBusy'
            : manualActionKey('nightActBusy', active),
      );
    }
    if (!allowParked && mount.isParked) return l10n.text('nightActWhyParked');
    if (capabilities == null) {
      return l10n.text(
        capabilitiesLoading
            ? 'nightScopeJogReadingCaps'
            : 'nightScopeWhyNoCapabilities',
      );
    }
    return null;
  }
}

/// Reads [NightMountFacts] for the current mount.
NightMountFacts watchNightMountFacts(WidgetRef ref) {
  final mount = ref.watch(mountStateProvider);
  final caps = ref.watch(mountCapabilitiesProvider(mount.deviceId ?? ''));
  return NightMountFacts(
    mount: mount,
    inputs: ref.watch(nightActionInputsProvider),
    capabilities: caps.valueOrNull,
    capabilitiesLoading: caps.isLoading,
  );
}

/// Shows a failed (or worded) command result; a silent success stays silent.
void showNightCommandResult(BuildContext context, CommandActionResult result) {
  if (!context.mounted) return;
  if (!result.isSuccess || result.hasMessage) {
    context.showCommandActionResult(result);
  }
}

class NightMountTab extends ConsumerStatefulWidget {
  const NightMountTab({super.key});

  @override
  ConsumerState<NightMountTab> createState() => _NightMountTabState();
}

class _NightMountTabState extends ConsumerState<NightMountTab> {
  /// The meridian countdown holds no timer of its own (its provider says
  /// why), so the widget that shows it ticks it.
  Timer? _flipTick;

  @override
  void initState() {
    super.initState();
    _flipTick = Timer.periodic(kMeridianCountdownTick, (_) {
      if (mounted) ref.invalidate(meridianCountdownProvider);
    });
  }

  @override
  void dispose() {
    _flipTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final facts = watchNightMountFacts(ref);
    final mount = facts.mount;

    final padReason = facts.baseReason(l10n);
    return NightPanelScroll(
      children: [
        const _PositionSection(),
        NightPanelSection(
          title: l10n.text('nightScopeMove'),
          trailing: l10n.text('nightScopeMoveHint'),
          children: [
            NightMountMovePad(
              isEnabled: padReason == null,
              disabledReason: padReason,
              deviceId: facts.connected ? mount.deviceId : null,
              capabilities: facts.capabilities,
              capabilitiesLoading: facts.capabilitiesLoading,
            ),
          ],
        ),
        const NightMountGoToSection(),
        const NightMountActionsSection(),
      ],
    );
  }
}

/// Position: the readouts and the tracking-rate buttons.
class _PositionSection extends ConsumerStatefulWidget {
  const _PositionSection();

  @override
  ConsumerState<_PositionSection> createState() => _PositionSectionState();
}

class _PositionSectionState extends ConsumerState<_PositionSection> {
  /// The tracking command in flight; its button shows busy.
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final facts = watchNightMountFacts(ref);
    final mount = facts.mount;
    final connected = facts.connected;
    final site = ref.watch(appObserverLocationProvider);
    final now = ref.watch(nightNowProvider);
    final countdown = ref.watch(meridianCountdownProvider);

    final ra = connected ? mount.ra : null;
    final dec = connected ? mount.dec : null;
    final lst = site == null
        ? null
        : computeLocalSiderealTimeHours(now, site.longitude);
    final hourAngle =
        lst == null || ra == null ? null : computeHourAngleHours(ra, lst);
    final toFlip = countdown.isArmed ? countdown.timeToFlip : null;
    final pierKey = switch (mount.sideOfPier?.trim().toLowerCase()) {
      'east' || 'pierside_east' => 'nightScopePierEast',
      'west' || 'pierside_west' => 'nightScopePierWest',
      _ => null,
    };

    final (status, statusColor) = !connected
        ? (l10n.text('nightScopeNotConnected'), colors.textMuted)
        : mount.isSlewing
            ? (l10n.text('nightScopeSlewing'), colors.warning)
            : mount.isParked
                ? (l10n.text('nightScopeParked'), colors.textMuted)
                : mount.isTracking
                    ? (
                        l10n.text(
                          'nightScopeTrackingAt',
                          params: {
                            'rate': l10n.text(_rateKey(mount.trackingRate)),
                          },
                        ),
                        colors.success,
                      )
                    : (l10n.text('nightScopeNotTracking'), colors.warning);

    return NightPanelSection(
      title: l10n.text('nightScopePosition'),
      trailing: status,
      trailingColor: statusColor,
      children: [
        NightPanelValues(
          columns: 2,
          items: [
            MetricGridItem(
              label: l10n.text('nightScopeRaJNow'),
              value: ra == null
                  ? null
                  : CoordinateFormat.ra(
                      ra,
                      style: SexagesimalStyle.compactLetters,
                      seconds: SecondsPrecision.integerRounded,
                      wrapHours: true,
                    ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeDecJNow'),
              value: dec == null
                  ? null
                  : CoordinateFormat.dec(
                      dec,
                      style: SexagesimalStyle.compactLetters,
                      seconds: SecondsPrecision.integerRounded,
                    ),
            ),
          ],
        ),
        NightPanelValues(
          items: [
            MetricGridItem(
              label: l10n.text('nightScopePier'),
              value: connected && pierKey != null ? l10n.text(pierKey) : null,
            ),
            MetricGridItem(
              label: l10n.text('nightScopeAltitude'),
              value: _degrees(connected ? mount.altitude : null),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeAzimuth'),
              value: _degrees(connected ? mount.azimuth : null),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeHourAngle'),
              value: hourAngle == null ? null : formatSignedHm(hourAngle),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeLst'),
              value: lst == null ? null : formatHm(lst),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeFlipIn'),
              value: toFlip == null ? null : formatCountdown(toFlip),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSlewingLabel'),
              value: connected
                  ? l10n
                      .text(mount.isSlewing ? 'nightScopeYes' : 'nightScopeNo')
                  : null,
              valueTone: mount.isSlewing && connected
                  ? MetricGridTone.warning
                  : MetricGridTone.neutral,
            ),
          ],
        ),
        // Two columns: four across leaves "Sidereal" no room for its label.
        NightPanelButtonGrid(
          columns: 2,
          buttons: [
            for (final rate in const [
              TrackingRate.sidereal,
              TrackingRate.lunar,
              TrackingRate.solar,
            ])
              _rateButton(l10n, facts, rate),
            _stopTrackingButton(l10n, facts),
          ],
        ),
      ],
    );
  }

  NightPanelButtonSpec _rateButton(
    SkotiqLocalizations l10n,
    NightMountFacts facts,
    TrackingRate rate,
  ) {
    final mount = facts.mount;
    final caps = facts.capabilities;
    final selected = facts.connected &&
        mount.isTracking &&
        !mount.isParked &&
        mount.trackingRate == rate;
    String? reason = facts.baseReason(l10n);
    if (reason == null && caps != null) {
      final needsRateChange = mount.trackingRate != rate;
      if (needsRateChange &&
          !(caps.canSetTrackingRate &&
              caps.supportedTrackingRates.contains(rate))) {
        reason = l10n.text(
          'nightScopeWhyRateUnsupported',
          params: {'rate': l10n.text(_rateKey(rate))},
        );
      } else if (!mount.isTracking && !caps.canSetTracking) {
        reason = l10n.text('nightScopeWhyNoTrackingControl');
      }
    }
    final id = 'rate.${rate.name}';
    return NightPanelButtonSpec(
      key: ValueKey<String>('nightMount.$id'),
      label: l10n.text(_rateKey(rate)),
      selected: selected,
      busy: _busy == id,
      disabledReason: reason,
      onPressed: reason != null || _busy != null
          ? null
          : () => _run(id, () => _trackAt(rate)),
    );
  }

  NightPanelButtonSpec _stopTrackingButton(
    SkotiqLocalizations l10n,
    NightMountFacts facts,
  ) {
    String? reason = facts.baseReason(l10n);
    if (reason == null && !facts.mount.isTracking) {
      reason = l10n.text('nightScopeNotTracking');
    } else if (reason == null && facts.capabilities?.canSetTracking != true) {
      reason = l10n.text('nightScopeWhyNoTrackingControl');
    }
    const id = 'stop';
    return NightPanelButtonSpec(
      key: const ValueKey<String>('nightMount.trackingStop'),
      label: l10n.text('nightScopeTrackingStop'),
      busy: _busy == id,
      disabledReason: reason,
      onPressed: reason != null || _busy != null
          ? null
          : () => _run(
                id,
                () => ref.read(mountCommandServiceProvider).setTracking(false),
              ),
    );
  }

  /// Sets [rate] when it differs, then makes sure the mount tracks.
  Future<CommandActionResult> _trackAt(TrackingRate rate) async {
    final commands = ref.read(mountCommandServiceProvider);
    if (ref.read(mountStateProvider).trackingRate != rate) {
      final result = await commands.setTrackingRate(rate);
      if (!result.isSuccess) return result;
    }
    if (ref.read(mountStateProvider).isTracking) return CommandActionResult.ok;
    return commands.setTracking(true);
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

String _rateKey(TrackingRate rate) => switch (rate) {
      TrackingRate.sidereal => 'nightScopeSidereal',
      TrackingRate.lunar => 'nightScopeLunar',
      TrackingRate.solar => 'nightScopeSolar',
      TrackingRate.king => 'nightScopeKing',
      TrackingRate.custom => 'nightScopeCustomRate',
    };

String? _degrees(double? value) =>
    value == null || !value.isFinite ? null : '${value.toStringAsFixed(1)}°';

/// `00h38m` for an angle in hours, wrapped into [0, 24).
String formatHm(double hours) {
  var minutes = (hours * 60).round() % (24 * 60);
  if (minutes < 0) minutes += 24 * 60;
  return '${(minutes ~/ 60).toString().padLeft(2, '0')}h'
      '${(minutes % 60).toString().padLeft(2, '0')}m';
}

/// `-0h59m`, `+1h05m`: a signed hour angle.
String formatSignedHm(double hours) {
  final minutes = (hours * 60).round();
  final sign = minutes < 0 ? '-' : '+';
  final magnitude = minutes.abs();
  return '$sign${magnitude ~/ 60}h${(magnitude % 60).toString().padLeft(2, '0')}m';
}

/// `2h06m`, `45m`, `0m` for a duration ahead.
String formatCountdown(Duration duration) {
  final minutes = duration.isNegative ? 0 : duration.inMinutes;
  if (minutes < 60) return '${minutes}m';
  return '${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m';
}
