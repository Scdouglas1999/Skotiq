// The Guide tab's lower sections: the guide star with its scatter plot,
// the guider's calibration, and the dither and settle values.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../utils/confirm_dialog.dart';
import '../../../../utils/guide_distance.dart';
import '../../../../utils/snackbar_helper.dart';
import '../../../../localization/skotiq_localizations.dart';
import '../../actions/night_action_controller.dart';
import '../../data/plan/night_plan_inputs.dart';
import '../../data/session/equipment_summary_provider.dart'
    show kNightGuideStopReasons;
import '../../data/session/guide_series_provider.dart';
import '../../data/session/session_events_provider.dart';
import '../../../../widgets/guide_star_view.dart';
import '../../night_control_contracts.dart';
import '../panel_widgets.dart';
import 'guide_metrics.dart';
import 'guide_scatter.dart';
import '../../../../router/settings_sections.dart';
import '../../../../router/app_routes.dart';

/// Where "Edit dither settings…" goes.
final String kNightGuideSettingsRoute =
    AppRoutes.settings(SettingsSectionId.phd2Guiding);

/// Edge of the star view and the scatter plot.
const double _plotSize = 124;

/// The guide star as the guider sees it, the recent steps as a scatter, and how
/// often the star was lost this session.
class NightGuideStarSection extends ConsumerWidget {
  const NightGuideStarSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(phd2StateProvider);
    final stats = ref.watch(guideStatsProvider);
    final image = ref.watch(starImageProvider);
    final samples = ref.watch(nightGuideRecentSamplesProvider);
    final rms = ref.watch(nightGuideRmsProvider);
    final scale = ref.watch(guideScaleProvider);
    final lost = ref.watch(
      nightSessionEventsProvider.select((events) => events.starLost),
    );
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final clock = ref.watch(clockProvider);
    final stopReason = ref.watch(guidingStopReasonProvider);
    final settleTimeout = ref.watch(guiderSettleTimeoutProvider);
    final guiderId = ref.watch(guiderStateProvider.select((g) => g.deviceId));
    final isPhd2 = guiderId == null || isPhd2DeviceId(guiderId);

    final acquiring = state == Phd2State.looping ||
        state == Phd2State.guiding ||
        state == Phd2State.calibrating ||
        state == Phd2State.settling;
    final idleMessage = l10n.text(
      acquiring ? 'nightScopeGuideWaitingImage' : 'nightScopeGuideLoopToSee',
    );

    final starView = image.when(
      data: (star) => GuideStarView(
        pixels: star.pixels,
        width: star.width,
        height: star.height,
        starX: star.starX,
        starY: star.starY,
        snr: stats.snr,
        statusMessage: idleMessage,
      ),
      loading: () => GuideStarView(statusMessage: idleMessage),
      error: (_, __) => GuideStarView(
        statusMessage: l10n.text('nightScopeGuideImageUnavailable'),
      ),
    );

    final scatterLabel = samples.isEmpty
        ? l10n.text('nightScopeGuideScatterEmpty')
        : l10n.text(
            'nightScopeGuideScatterLabel',
            params: {
              'count': '${samples.length}',
              'rms': formatGuide(rms.total, scale) ?? kReadoutUnknown,
              'scale': NightGuideScatter.spanLabel(
                NightGuideScatter.scaleFor(samples),
                scale,
              ),
            },
          );

    final lastLost = lost.isEmpty ? null : lost.last;
    final lostText = lastLost == null
        ? l10n.text('nightScopeGuideLostNone')
        : l10n.text(
            'nightScopeGuideLost',
            params: {
              'count': '${lost.length}',
              'time': ClockFormat.hm(clock.toNightClock(lastLost)),
            },
          );
    final settle = settings == null ? null : GuideSettle.of(settings).pixels;

    // The star view's empty state is an icon over a sentence, so the square
    // grows with the text size rather than clipping it.
    final plotSize = MediaQuery.textScalerOf(
      context,
    ).scale(_plotSize).clamp(_plotSize, _plotSize * 1.4);

    return NightPanelSection(
      title: l10n.text('nightScopeGuideStar'),
      trailing: l10n.text(
        isPhd2 ? 'nightScopeGuideLivePhd2' : 'nightScopeGuideLive',
      ),
      children: [
        Row(
          children: [
            SizedBox.square(dimension: plotSize, child: starView),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: SizedBox(
                height: plotSize,
                child: NightGuideScatter(
                  samples: samples,
                  semanticLabel: scatterLabel,
                  arcsecPerPixel: scale,
                ),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: SkotiqTokens.spaceMd,
          runSpacing: 2,
          children: [
            // A planned stop says what it is for, so it is never read as
            // lost guiding.
            if (stopReason != null)
              NightPanelNote(
                key: const ValueKey<String>('nightGuide.stopReason'),
                guideStopReasonLabel(l10n, stopReason),
                tone: MetricTone.neutral,
              ),
            if (settleTimeout != null)
              NightPanelNote(
                key: const ValueKey<String>('nightGuide.settleTimedOut'),
                l10n.text(
                  'nightScopeGuideSettleTimedOut',
                  params: {
                    'time':
                        ClockFormat.hm(clock.toNightClock(settleTimeout.at)),
                  },
                ),
              ),
            NightPanelNote(
              lostText,
              tone: lost.isEmpty ? null : MetricTone.warning,
            ),
            if (settle != null)
              NightPanelNote(
                l10n.text(
                  'nightScopeGuideSettleBelow',
                  params: {'px': settle.toStringAsFixed(1)},
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The guider's calibration: whether it is valid and its angle and rates;
/// with PHD2, flipping or clearing it.
class NightGuideCalibrationSection extends ConsumerStatefulWidget {
  const NightGuideCalibrationSection({super.key});

  @override
  ConsumerState<NightGuideCalibrationSection> createState() =>
      _NightGuideCalibrationSectionState();
}

class _NightGuideCalibrationSectionState
    extends ConsumerState<NightGuideCalibrationSection> {
  /// The calibration command in flight.
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final calibration = ref.watch(calibrationStateProvider);
    final clock = ref.watch(clockProvider);
    final inputs = ref.watch(nightActionInputsProvider);
    final guiderId = ref.watch(guiderStateProvider.select((g) => g.deviceId));
    final isPhd2 = guiderId == null || isPhd2DeviceId(guiderId);
    final at = calibration.calibratedAt;
    final status = !calibration.isCalibrated
        ? l10n.text('nightScopeGuideNotCalibrated')
        : at == null
            ? l10n.text('nightScopeGuideCalibrated')
            : l10n.text(
                'nightScopeGuideCalibratedAt',
                params: {'time': ClockFormat.hm(clock.toNightClock(at))},
              );
    String? rate(double? value) =>
        value == null || !value.isFinite ? null : value.toStringAsFixed(2);
    final angle = calibration.rotationAngle;

    final reason = !inputs.canCommand
        ? l10n.text('nightActWhyNoHost')
        : inputs.runActive
            ? l10n.text('nightActWhyRunOwns')
            : _busy != null
                ? l10n.text('nightScopeWhyGuiderBusy')
                : null;
    final flipReason = reason ??
        (calibration.isCalibrated
            ? null
            : l10n.text('nightScopeWhyNotCalibrated'));

    return NightPanelSection(
      title: l10n.text('nightScopeGuideCalibration'),
      trailing: status,
      trailingTone:
          calibration.isCalibrated ? MetricTone.good : MetricTone.warning,
      children: [
        NightPanelValues(
          items: [
            MetricGridItem(
              label: l10n.text('nightScopeGuideRaAngle'),
              value: angle == null || !angle.isFinite
                  ? null
                  : '${angle.toStringAsFixed(1)}°',
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideRaRate'),
              value: _withUnit(rate(calibration.raRate), 'px/s'),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideDecRate'),
              value: _withUnit(rate(calibration.decRate), 'px/s'),
            ),
          ],
        ),
        // Only PHD2 takes these; the built-in guider calibrates itself
        // when guiding starts.
        if (isPhd2)
          NightPanelButtonGrid(
            columns: 2,
            buttons: [
              NightPanelButtonSpec(
                key: const ValueKey<String>('nightGuide.flipCal'),
                label: l10n.text('nightScopeGuideFlipCal'),
                busy: _busy == 'flipCal',
                disabledReason: flipReason,
                onPressed: flipReason == null
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
                disabledReason: reason,
                onPressed:
                    reason == null ? () => unawaited(_confirmClear()) : null,
              ),
            ],
          ),
      ],
    );
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
          l10n.text(
            'nightScopeGuideCommandFailed',
            params: {'error': userFacingError(e)},
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}

/// The dither and settle values, and where to change them.
class NightGuideDitherSection extends ConsumerWidget {
  const NightGuideDitherSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final settle = settings == null ? null : GuideSettle.of(settings);
    final every = ref.watch(nightDitherEveryProvider);
    String? seconds(double? value) =>
        value == null ? null : '${value.round()} s';
    return NightPanelSection(
      title: l10n.text('nightScopeGuideDither'),
      trailing: l10n.text('nightScopeGuideDitherUsedBy'),
      children: [
        NightPanelValues(
          items: [
            MetricGridItem(
              label: l10n.text('nightScopeGuideEvery'),
              value: settings == null
                  ? null
                  : every == null
                      ? l10n.text('nightScopeGuideDitherOff')
                      : l10n.text(
                          'nightScopeGuideFrames',
                          params: {'count': '$every'},
                        ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideAmount'),
              value: formatPx(settle?.ditherPixels, decimals: 0),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideRaOnly'),
              value: settle == null
                  ? null
                  : l10n.text(
                      settle.ditherRaOnly ? 'nightScopeYes' : 'nightScopeNo',
                    ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideSettle'),
              value: formatPx(settle?.pixels, decimals: 1),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideSettleFor'),
              value: seconds(settle?.seconds),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideTimeout'),
              value: seconds(settle?.timeoutSeconds),
            ),
          ],
        ),
        NightPanelButtonGrid(
          columns: 1,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightGuide.editDither'),
              label: l10n.text('nightScopeGuideEditDither'),
              onPressed: () => context.go(kNightGuideSettingsRoute),
            ),
          ],
        ),
      ],
    );
  }
}

/// The guide tab's words for why the guider is stopped (see
/// `guidingStopReasonProvider`).
String guideStopReasonLabel(SkotiqLocalizations l10n, String reason) {
  return kNightGuideStopReasons.contains(reason)
      ? l10n.text('nightScopeGuideHeld_$reason')
      : l10n.text('nightScopeGuideHeldOther', params: {'reason': reason});
}

String? _withUnit(String? value, String unit) =>
    value == null ? null : '$value $unit';
