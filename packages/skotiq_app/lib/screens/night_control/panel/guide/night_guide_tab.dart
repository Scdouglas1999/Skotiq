// The right panel's Guide tab (board TonightGuide): the guider's state and
// error, its controls, the guide star, calibration, and the dither and
// settle values the run uses.
//
// Errors are in arcseconds when the guider reports its pixel scale and in
// guide-camera pixels otherwise. PHD2's own settings (dither amount, settle
// threshold) are pixels either way.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../utils/guide_distance.dart';
import '../../../../utils/snackbar_helper.dart';
import '../../../../widgets/phd2_connection_dialog.dart';
import '../../actions/manual_action_gating.dart';
import '../../actions/night_action_controller.dart';
import '../../night_control_contracts.dart';
import '../mount/night_panel_parts.dart';
import 'guide_metrics.dart';
import 'guide_sections.dart';

/// The state label and its tone for a PHD2 state.
(String key, MetricGridTone tone) nightGuiderStateKey(Phd2State state) =>
    switch (state) {
      Phd2State.stopped => ('nightScopeGuideStopped', MetricGridTone.neutral),
      Phd2State.selected => ('nightScopeGuideSelected', MetricGridTone.neutral),
      Phd2State.looping => ('nightScopeGuideLooping', MetricGridTone.warning),
      Phd2State.calibrating => (
          'nightScopeGuideCalibrating',
          MetricGridTone.warning
        ),
      Phd2State.guiding => ('nightScopeGuideGuiding', MetricGridTone.good),
      Phd2State.settling => ('nightScopeGuideSettling', MetricGridTone.warning),
      Phd2State.paused => ('nightScopeGuidePaused', MetricGridTone.warning),
      Phd2State.lostLock => ('nightScopeGuideLostLock', MetricGridTone.bad),
      Phd2State.unknown => ('nightScopeGuideUnknown', MetricGridTone.warning),
    };

class NightGuideTab extends ConsumerWidget {
  const NightGuideTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guider = ref.watch(guiderStateProvider);
    final connected = guider.connectionState == DeviceConnectionState.connected;
    if (!connected) {
      return const NightPanelScroll(children: [_NoGuiderSection()]);
    }
    return const NightPanelScroll(
      children: [
        _GuiderSection(),
        NightGuideStarSection(),
        NightGuideCalibrationSection(),
        NightGuideDitherSection(),
      ],
    );
  }
}

/// No guider connected: say so, and offer what connects the profile's guider.
class _NoGuiderSection extends ConsumerStatefulWidget {
  const _NoGuiderSection();

  @override
  ConsumerState<_NoGuiderSection> createState() => _NoGuiderSectionState();
}

class _NoGuiderSectionState extends ConsumerState<_NoGuiderSection> {
  bool _connecting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final guider = ref.watch(guiderStateProvider);
    final canCommand = ref.watch(backendCanCommandProvider);
    final connecting = _connecting ||
        guider.connectionState == DeviceConnectionState.connecting;
    final profileGuider = ref.watch(profileGuiderProvider);
    if (profileGuider.kind != ProfileGuiderKind.phd2) {
      return _deviceGuiderSection(profileGuider, canCommand, connecting);
    }
    final reason = !canCommand
        ? l10n.text('nightActWhyNoHost')
        : connecting
            ? l10n.text('nightScopeGuideConnecting')
            : null;
    return NightPanelSection(
      title: l10n.text('nightScopePhd2'),
      trailing: l10n.text('nightScopeNotConnected'),
      trailingColor: colors.warning,
      children: [
        NightPanelNote(l10n.text('nightScopeGuideNoPhd2')),
        NightPanelButtonGrid(
          columns: 2,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.openPhd2'),
              label: l10n.text('nightScopeGuideOpenPhd2'),
              emphasized: true,
              busy: connecting,
              tooltip: l10n.text('nightScopeGuideOpenPhd2Hint'),
              disabledReason: reason,
              onPressed: reason == null ? () => unawaited(_open()) : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.connect'),
              label: l10n.text('nightScopeGuideConnect'),
              disabledReason: reason,
              onPressed: reason == null
                  ? () => unawaited(Phd2ConnectionDialog.show(context, ref))
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  /// The profile guides with a device guider (the built-in guider or a
  /// driver), or names none: offer only what applies, never PHD2.
  Widget _deviceGuiderSection(
    ProfileGuider profileGuider,
    bool canCommand,
    bool connecting,
  ) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    if (profileGuider.kind == ProfileGuiderKind.none) {
      return NightPanelSection(
        title: l10n.text('nightScopeGuider'),
        trailing: l10n.text('nightScopeNotConnected'),
        trailingColor: colors.warning,
        children: [NightPanelNote(l10n.text('nightScopeGuideNone'))],
      );
    }
    final reason = !canCommand
        ? l10n.text('nightActWhyNoHost')
        : connecting
            ? l10n.text('nightScopeGuideConnectingDevice')
            : null;
    return NightPanelSection(
      title: l10n.text('nightScopeGuider'),
      trailing: l10n.text('nightScopeNotConnected'),
      trailingColor: colors.warning,
      children: [
        NightPanelNote(l10n.text('nightScopeGuideNoDevice')),
        NightPanelButtonGrid(
          columns: 2,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.connectDevice'),
              label: l10n.text('nightCtrGuideConnect'),
              emphasized: true,
              busy: connecting,
              disabledReason: reason,
              onPressed: reason == null
                  ? () => unawaited(_connectDevice(profileGuider))
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _connectDevice(ProfileGuider profileGuider) async {
    final l10n = context.l10n;
    final guiderId = profileGuider.guiderId;
    if (guiderId == null) return;
    setState(() => _connecting = true);
    try {
      await ref.read(deviceServiceProvider).connectDeviceGuider(
            guiderId,
            guideCameraId: profileGuider.guideCameraId,
          );
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
          l10n.text('nightCtrGuideConnectFailed',
              params: {'detail': userFacingError(e)}),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Connects to the PHD2 the settings name; on this computer that starts
  /// PHD2 first when it is not running.
  Future<void> _open() async {
    final l10n = context.l10n;
    setState(() => _connecting = true);
    try {
      final settings = await ref.read(appSettingsProvider.future);
      await ref
          .read(phd2ControllerProvider)
          .connect(settings.phd2Host, settings.phd2Port);
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
          l10n.text('nightScopeGuideConnectFailed',
              params: {'error': userFacingError(e)}),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }
}

/// The guider's state, its error in px, and its controls.
class _GuiderSection extends ConsumerStatefulWidget {
  const _GuiderSection();

  @override
  ConsumerState<_GuiderSection> createState() => _GuiderSectionState();
}

class _GuiderSectionState extends ConsumerState<_GuiderSection> {
  /// The guider command in flight.
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final guider = ref.watch(guiderStateProvider);
    final state = ref.watch(phd2StateProvider);
    final stats = ref.watch(guideStatsProvider);
    final rms = ref.watch(nightGuideRmsProvider);
    final inputs = ref.watch(nightActionInputsProvider);
    final isPhd2 = guider.deviceId == null || isPhd2DeviceId(guider.deviceId!);

    final (stateKey, tone) = nightGuiderStateKey(state);
    // SNR and mass are reported once a star is measured; zero means none.
    final measured = stats.frameCount > 0 || stats.loopFrameCount > 0;
    final snr = measured && stats.snr > 0 ? stats.snr : null;
    final mass = measured && stats.starMass > 0 ? stats.starMass : null;

    // Arcseconds when the guider reports its pixel scale, else pixels.
    final scale = ref.watch(guideScaleProvider);
    final metrics = [
      MetricGridItem(
        label: l10n.text('nightScopeGuideRaRms'),
        value: formatGuide(rms.ra, scale),
      ),
      MetricGridItem(
        label: l10n.text('nightScopeGuideDecRms'),
        value: formatGuide(rms.dec, scale),
      ),
      MetricGridItem(
        label: l10n.text('nightScopeGuideTotalRms'),
        value: formatGuide(rms.total, scale),
      ),
      MetricGridItem(
        label: l10n.text('nightScopeGuideSnr'),
        value: snr?.toStringAsFixed(0),
      ),
      MetricGridItem(
        label: l10n.text('nightScopeGuideMass'),
        value: mass == null ? null : formatMass(mass),
      ),
      MetricGridItem(
        label: l10n.text('nightScopeGuidePeak'),
        value: formatGuide(rms.peak, scale),
      ),
    ];

    // A loaded run owns the guider; only Dither, which goes through the
    // action controller, stays available.
    String? reason() {
      if (!inputs.canCommand) return l10n.text('nightActWhyNoHost');
      if (inputs.runActive) return l10n.text('nightActWhyRunOwns');
      if (_busy != null) return l10n.text('nightScopeWhyGuiderBusy');
      return null;
    }

    final looping = state == Phd2State.looping;
    final guiding = state == Phd2State.guiding ||
        state == Phd2State.calibrating ||
        state == Phd2State.settling;
    final held = state == Phd2State.paused || state == Phd2State.lostLock;
    final loopReason = reason() ??
        (looping
            ? l10n.text('nightScopeWhyLooping')
            : guiding || held
                ? l10n.text('nightScopeWhyStopFirst')
                : null);
    final findReason = reason() ??
        (looping || state == Phd2State.selected
            ? null
            : l10n.text('nightScopeWhyLoopFirst'));
    final guideReason = reason() ??
        (guiding
            ? l10n.text('nightScopeWhyGuiding')
            : held || state == Phd2State.unknown
                ? l10n.text('nightScopeWhyStopFirst')
                : null);
    final stopReason = reason() ??
        (state == Phd2State.stopped || state == Phd2State.selected
            ? l10n.text('nightScopeWhyNothingToStop')
            : null);
    final ditherReason =
        manualActionDisabledReason(inputs, ManualActionId.dither)
            ?.resolve(l10n);
    final ditherInFlight =
        inputs.action.isBusy && inputs.action.active == ManualActionId.dither;

    return NightPanelSection(
      title: isPhd2
          ? l10n.text('nightScopePhd2')
          : (guider.deviceName ?? l10n.text('nightScopeGuider')),
      trailing: l10n.text(stateKey),
      trailingColor: MetricGrid.valueColor(tone, colors),
      children: [
        NightPanelValues(
          items: metrics,
          semanticLabel: l10n.text(
            scale == null
                ? 'nightScopeGuideMetricsLabel'
                : 'nightScopeGuideMetricsLabelArcsec',
          ),
        ),
        NightPanelButtonGrid(
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.loop'),
              label: l10n.text('nightScopeGuideLoop'),
              tooltip: l10n.text('nightScopeGuideLoopHint'),
              busy: _busy == 'loop',
              disabledReason: loopReason,
              onPressed: loopReason == null
                  ? () => _run(
                        'loop',
                        () => ref.read(phd2ControllerProvider).loop(),
                      )
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.findStar'),
              label: l10n.text('nightScopeGuideFindStar'),
              tooltip: l10n.text('nightScopeGuideFindStarHint'),
              busy: _busy == 'find',
              disabledReason: findReason,
              onPressed:
                  findReason == null ? () => _run('find', _findStar) : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.guide'),
              label: l10n.text('nightScopeGuideGuide'),
              emphasized: true,
              busy: _busy == 'guide',
              tooltip: l10n.text('nightScopeGuideGuideHint'),
              disabledReason: guideReason,
              onPressed:
                  guideReason == null ? () => _run('guide', _guide) : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.stop'),
              label: l10n.text('nightScopeGuideStop'),
              tooltip: l10n.text('nightScopeGuideStopHint'),
              busy: _busy == 'stop',
              disabledReason: stopReason,
              onPressed: stopReason == null
                  ? () => _run(
                        'stop',
                        () => ref.read(phd2ControllerProvider).stopGuiding(),
                      )
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.dither'),
              label: l10n.text('nightScopeGuideDitherNow'),
              tooltip: l10n.text('nightScopeGuideDitherHint'),
              busy: ditherInFlight,
              disabledReason: ditherReason,
              onPressed: ditherReason == null
                  ? () => unawaited(ref.read(nightActionApiProvider).dither())
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _findStar() async {
    final l10n = context.l10n;
    await ref.read(lockPositionProvider.notifier).findStar();
    if (!mounted) return;
    if (ref.read(lockPositionProvider) == null) {
      context.showWarningSnackBar(l10n.text('nightScopeGuideNoStarFound'));
    }
  }

  /// Calibrates when the guider needs it, then guides with the settle
  /// settings the run uses.
  Future<void> _guide() {
    final settle = GuideSettle.of(
      ref.read(appSettingsProvider).valueOrNull ?? const AppSettingsState(),
    );
    return ref.read(phd2ControllerProvider).startGuiding(
          settlePixels: settle.pixels,
          settleTime: settle.seconds,
          settleTimeout: settle.timeoutSeconds,
        );
  }

  Future<void> _run(String id, Future<void> Function() command) async {
    final l10n = context.l10n;
    setState(() => _busy = id);
    try {
      await command();
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar(
          l10n.text('nightScopeGuideCommandFailed',
              params: {'error': userFacingError(e)}),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}
