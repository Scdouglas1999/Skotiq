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
import '../../../../utils/confirm_dialog.dart';
import '../../../../utils/snackbar_helper.dart';
import '../../../../widgets/phd2_connection_dialog.dart';
import '../../actions/manual_action_gating.dart';
import '../../actions/night_action_controller.dart';
import '../../data/session/guide_series_provider.dart';
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

/// No guider connected: say so, and offer to start PHD2 and connect.
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
          l10n.text('nightScopeGuideConnectFailed', params: {'error': '$e'}),
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
    final calibration = ref.watch(calibrationStateProvider);
    final inputs = ref.watch(nightActionInputsProvider);
    final isPhd2 = guider.deviceId == null || isPhd2DeviceId(guider.deviceId!);

    final (stateKey, tone) = nightGuiderStateKey(state);
    // SNR and mass are reported once a star is measured; zero means none.
    final measured = stats.frameCount > 0 || stats.loopFrameCount > 0;
    final snr = measured && stats.snr > 0 ? stats.snr : null;
    final mass = measured && stats.starMass > 0 ? stats.starMass : null;

    // Arcseconds when the guider reports its pixel scale, else pixels.
    final scale = ref.watch(nightGuideScaleProvider);
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

    // Guiding belongs to a loaded run; only Dither, which goes through the
    // action controller, stays available.
    String? reason({bool phd2Only = false}) {
      if (!inputs.canCommand) return l10n.text('nightActWhyNoHost');
      if (inputs.runActive) return l10n.text('nightActWhyRunOwns');
      if (_busy != null) return l10n.text('nightScopeWhyGuiderBusy');
      if (phd2Only && !isPhd2) return l10n.text('nightScopeWhyPhd2Only');
      return null;
    }

    final looping = state == Phd2State.looping;
    final active = state == Phd2State.guiding ||
        state == Phd2State.calibrating ||
        state == Phd2State.settling ||
        state == Phd2State.paused ||
        state == Phd2State.lostLock;
    final loopReason = reason() ??
        (looping
            ? l10n.text('nightScopeWhyLooping')
            : active
                ? l10n.text('nightScopeWhyStopFirst')
                : null);
    final findReason = reason() ??
        (looping || state == Phd2State.selected
            ? null
            : l10n.text('nightScopeWhyLoopFirst'));
    final stopReason = reason() ??
        (state == Phd2State.stopped || state == Phd2State.selected
            ? l10n.text('nightScopeWhyNothingToStop')
            : null);
    final flipCalReason = reason(phd2Only: true) ??
        (calibration.isCalibrated
            ? null
            : l10n.text('nightScopeWhyNotCalibrated'));
    final clearCalReason = reason(phd2Only: true);
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
          semanticLabel: l10n.text('nightScopeGuideMetricsLabel'),
        ),
        NightPanelButtonGrid(
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.loop'),
              label: l10n.text('nightScopeGuideLoop'),
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
              busy: _busy == 'find',
              disabledReason: findReason,
              onPressed:
                  findReason == null ? () => _run('find', _findStar) : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.stop'),
              label: l10n.text('nightScopeGuideStop'),
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
              busy: ditherInFlight,
              disabledReason: ditherReason,
              onPressed: ditherReason == null
                  ? () => unawaited(ref.read(nightActionApiProvider).dither())
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.flipCal'),
              label: l10n.text('nightScopeGuideFlipCal'),
              busy: _busy == 'flipCal',
              disabledReason: flipCalReason,
              onPressed: flipCalReason == null
                  ? () => _run(
                        'flipCal',
                        () => ref
                            .read(calibrationStateProvider.notifier)
                            .flipCalibration(),
                      )
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.clearCal'),
              label: l10n.text('nightScopeGuideClearCal'),
              busy: _busy == 'clearCal',
              disabledReason: clearCalReason,
              onPressed: clearCalReason == null
                  ? () => unawaited(_confirmClear())
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

  Future<void> _confirmClear() async {
    final l10n = context.l10n;
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: l10n.text('nightScopeGuideClearTitle'),
      message: l10n.text('nightScopeGuideClearBody'),
      confirmLabel: l10n.text('nightScopeGuideClearCal'),
      cancelLabel: l10n.text('cancel'),
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      'clearCal',
      () => ref.read(calibrationStateProvider.notifier).clearCalibration(),
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
          l10n.text('nightScopeGuideCommandFailed', params: {'error': '$e'}),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}
