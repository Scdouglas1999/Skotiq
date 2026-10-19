// The Guide tab's lower sections: the guide star with its scatter plot,
// PHD2's calibration, and the dither and settle values.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../data/plan/night_plan_inputs.dart';
import '../../data/session/guide_series_provider.dart';
import '../../data/session/session_events_provider.dart';
import '../mount/night_panel_parts.dart';
import 'guide_metrics.dart';
import 'guide_scatter.dart';

/// Where "Edit dither settings…" goes.
const String kNightGuideSettingsRoute = '/settings?section=phd2-guiding';

/// Edge of the star view and the scatter plot.
const double _plotSize = 124;

/// The guide star as PHD2 sees it, the recent steps as a scatter, and how
/// often the star was lost this session.
class NightGuideStarSection extends ConsumerWidget {
  const NightGuideStarSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final state = ref.watch(phd2StateProvider);
    final stats = ref.watch(guideStatsProvider);
    final image = ref.watch(starImageProvider);
    final samples = ref.watch(nightGuideSamplesProvider);
    final rms = ref.watch(nightGuideRmsProvider);
    final lost = ref.watch(
      nightSessionEventsProvider.select((events) => events.starLost),
    );
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final clock = ref.watch(clockProvider);

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
              'rms': formatPx(rms.total) ?? kReadoutUnknown,
              'scale': NightGuideScatter.scaleFor(samples).toString(),
            },
          );

    final lastLost = lost.isEmpty ? null : lost.last;
    final lostText = lastLost == null
        ? l10n.text('nightScopeGuideLostNone')
        : l10n.text(
            'nightScopeGuideLost',
            params: {
              'count': '${lost.length}',
              'time': _clockTime(clock.toNightClock(lastLost)),
            },
          );
    final settle = settings?.settleThreshold;

    // The star view's empty state is an icon over a sentence, so the square
    // grows with the text size rather than clipping it.
    final plotSize = MediaQuery.textScalerOf(context)
        .scale(_plotSize)
        .clamp(_plotSize, _plotSize * 1.4);

    return NightPanelSection(
      title: l10n.text('nightScopeGuideStar'),
      trailing: l10n.text('nightScopeGuideLive'),
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
                ),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: SkotiqTokens.spaceMd,
          runSpacing: 2,
          children: [
            NightPanelNote(
              lostText,
              color: lost.isEmpty ? null : colors.warning,
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

/// PHD2's calibration: whether it is valid and its angle and rates.
class NightGuideCalibrationSection extends ConsumerWidget {
  const NightGuideCalibrationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final calibration = ref.watch(calibrationStateProvider);
    final clock = ref.watch(clockProvider);
    final at = calibration.calibratedAt;
    final status = !calibration.isCalibrated
        ? l10n.text('nightScopeGuideNotCalibrated')
        : at == null
            ? l10n.text('nightScopeGuideCalibrated')
            : l10n.text(
                'nightScopeGuideCalibratedAt',
                params: {'time': _clockTime(clock.toNightClock(at))},
              );
    String? rate(double? value) =>
        value == null || !value.isFinite ? null : value.toStringAsFixed(2);
    final angle = calibration.rotationAngle;
    return NightPanelSection(
      title: l10n.text('nightScopeGuideCalibration'),
      trailing: status,
      trailingColor: calibration.isCalibrated ? colors.success : colors.warning,
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
      ],
    );
  }
}

/// The dither and settle values, and where to change them.
class NightGuideDitherSection extends ConsumerWidget {
  const NightGuideDitherSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final every = ref.watch(nightDitherEveryProvider);
    String? seconds(num? value) => value == null ? null : '$value s';
    return NightPanelSection(
      title: l10n.text('nightScopeGuideDither'),
      trailing: l10n.text('nightScopeGuideDitherUsedBy'),
      children: [
        NightPanelValues(
          items: [
            MetricGridItem(
              label: l10n.text('nightScopeGuideEvery'),
              value: every == null
                  ? null
                  : l10n.text(
                      'nightScopeGuideFrames',
                      params: {'count': '$every'},
                    ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideAmount'),
              value: settings == null
                  ? null
                  : formatPx(
                      ditherScalePixels(settings.ditherScale),
                      decimals: 0,
                    ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideRaOnly'),
              value: settings == null
                  ? null
                  : l10n.text(
                      settings.ditherRaOnly ? 'nightScopeYes' : 'nightScopeNo',
                    ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideSettle'),
              value: formatPx(settings?.settleThreshold, decimals: 1),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideSettleFor'),
              value: seconds(settings?.settleTime),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeGuideTimeout'),
              value: seconds(settings?.settleTimeout),
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

String? _withUnit(String? value, String unit) =>
    value == null ? null : '$value $unit';

/// `23:12`.
String _clockTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
