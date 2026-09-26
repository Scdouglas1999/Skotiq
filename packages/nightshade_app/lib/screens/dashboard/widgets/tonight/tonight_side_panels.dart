// The c5 column beside the first-light checklist (06 §Tonight, first-run
// state): the moon, the weather and last night.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:nightshade_core/nightshade_core.dart' hide TwilightTimes;
import 'package:nightshade_ui/nightshade_ui.dart';

import '../../../../localization/nightshade_localizations.dart';
import '../standby/moon_card.dart' show MoonPainter;
import 'tonight_night.dart';
import '../../../sequencer/run_status_presentation.dart';

/// The phase disc's diameter (06 §Tonight: 56 px).
const double _discSize = 56;

/// Phase disc plus Illuminated / Moonset / Moonrise.
class TonightMoonPanel extends ConsumerWidget {
  const TonightMoonPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = NightshadeColors.of(context);
    final l10n = context.l10n;
    final night = ref.watch(tonightNightProvider);
    final illumination = night?.moonIlluminationPercent;
    final percent = night?.moonIlluminationRounded;

    return NightshadePanel(
      head: PanelHead(icon: LucideIcons.moon, label: l10n.text('tnMoon')),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: _discSize,
            height: _discSize,
            // No illumination figure, no disc. A 0 % phase paints a fully dark
            // circle that reads as a confident new moon, and the Illuminated
            // readout beside it is showing '—' for the very same missing value.
            child: illumination == null
                ? null
                : CustomPaint(
                    painter: MoonPainter(
                      // MoonPainter takes 0–100, which is what the provider
                      // hands us.
                      illumination: illumination,
                      // Waxing between new and full: the moon that sets AFTER
                      // the sun is the one lit on its western limb.
                      waxing: _isWaxing(night),
                      litColor: colors.textPrimary,
                      darkColor: colors.well,
                      borderColor: colors.border,
                    ),
                  ),
          ),
          const SizedBox(width: NightshadeTokens.spaceLg),
          Expanded(
            child: ReadoutRow(
              gap: NightshadeTokens.spaceXl,
              children: <Readout>[
                Readout(
                  value: percent == null ? null : '$percent',
                  unit: '%',
                  label: l10n.text('tnIlluminated'),
                ),
                Readout(
                  value: night?.moonSet == null
                      ? null
                      : tonightClock(night!.moonSet!),
                  label: l10n.text('tnMoonset'),
                ),
                Readout(
                  value: night?.moonRise == null
                      ? null
                      : tonightClock(night!.moonRise!),
                  label: l10n.text('tnMoonrise'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A moon that sets after it rises on the same night is waxing.
  ///
  /// Not an ephemeris — the disc only needs to know which limb to light, and
  /// this is the one signal the night's own times already carry.
  static bool _isWaxing(TonightNight? night) {
    final rise = night?.moonRise;
    final set = night?.moonSet;
    if (rise == null || set == null) return true;
    return set.isAfter(rise);
  }
}

/// Whether the mount will be parked for you, and the way to change that.
///
/// Deliberately reads the weather CONFIG (`weatherSettingsDataProvider`) and the
/// weather DEVICE (`weatherStateProvider`), never `weatherSafetyProvider`.
/// Watching the evaluator is what STARTS it: this panel is on screen in the
/// first-run state, on a fresh install, before any equipment exists, and arming
/// the safety loop there is how a rig with fail-closed set and no sensor ends up
/// issuing a PARK a few minutes after the mount first connects. The safety
/// panel in the connected grid watches the evaluator, because by then the
/// sequencer has armed it anyway.
class TonightWeatherPanel extends ConsumerWidget {
  const TonightWeatherPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = NightshadeColors.of(context);
    final l10n = context.l10n;
    final settings = ref.watch(weatherSettingsDataProvider).valueOrNull;
    final device = ref.watch(weatherStateProvider);
    final monitoring = settings?.weatherSafetyEnabled ?? false;
    final haveSensor =
        device.connectionState == DeviceConnectionState.connected;

    final (String label, ChipTone tone) = switch ((monitoring, haveSensor)) {
      (false, _) => (l10n.text('tnNotMonitored'), ChipTone.neutral),
      (true, false) => (l10n.text('tnNoWeatherData'), ChipTone.warning),
      (true, true) => (l10n.text('tnMonitored'), ChipTone.success),
    };

    return NightshadePanel(
      head: PanelHead(
        icon: LucideIcons.cloudSun,
        label: l10n.text('tnWeather'),
        trailing: <Widget>[NightshadeChip(label: label, tone: tone)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            monitoring
                ? l10n.text('tnWeatherOnBody')
                : l10n.text('tnWeatherOffBody'),
            style: NightshadeTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          NightshadeButton(
            label: l10n.text('tnOpenWeather'),
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => context.go('/weather'),
          ),
        ],
      ),
    );
  }
}

/// Last night's run, or the promise of one.
class TonightLastNightPanel extends ConsumerWidget {
  const TonightLastNightPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = NightshadeColors.of(context);
    final l10n = context.l10n;
    // `watchAllRuns()` orders by startedAt desc, so the head is the newest run.
    final lastRun = ref.watch(sequenceRunsProvider).maybeWhen(
          data: (runs) => runs.isEmpty ? null : runs.first,
          orElse: () => null,
        );
    String? failure;
    final statsJson = lastRun?.statsJson;
    if (lastRun != null && lastRun.status == 'failed' && statsJson != null) {
      try {
        final parsed = ParsedRunStats.fromJson(statsJson);
        final headline = runFailureHeadline(
          terminalCause: parsed.terminalCause,
          errors: parsed.errorMessages,
        );
        if (headline != null) failure = runFailureMessage(headline);
      } on FormatException {
        // Older runs may have an unreadable stats payload; the outcome remains visible.
      }
    }
    // Only claim "Last night" when the run genuinely was last night; a
    // weeks-old run under that header reads as a stale-data bug.
    final recent = lastRun != null &&
        DateTime.now().difference(lastRun.startedAt) <
            const Duration(hours: 24);

    return NightshadePanel(
      head: PanelHead(
        icon: LucideIcons.history,
        label: l10n.text(recent ? 'tnLastNight' : 'tnLastRun'),
      ),
      child: lastRun == null
          ? Text(
              l10n.text('tnNoRunsYet'),
              style: NightshadeTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  lastRun.sequenceName,
                  style: NightshadeTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: NightshadeTokens.spaceSm),
                if (failure != null) ...[
                  Text(failure,
                      style: NightshadeTypography.bodySm
                          .copyWith(color: colors.error)),
                  const SizedBox(height: NightshadeTokens.spaceSm),
                ],
                ReadoutRow(
                  gap: NightshadeTokens.spaceXl,
                  children: <Readout>[
                    Readout(
                      value: tonightClock(lastRun.startedAt.toLocal()),
                      label: l10n.text('tnStarted'),
                      size: ReadoutSize.sm,
                    ),
                    Readout(
                      value: runStatusLabel(lastRun.status),
                      label: l10n.text('tnOutcome'),
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
