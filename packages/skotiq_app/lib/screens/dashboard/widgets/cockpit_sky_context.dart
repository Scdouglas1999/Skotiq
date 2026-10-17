import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' show Clock, clockProvider;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/observing_site.dart';
import '../../sequencer/widgets/run_dashboard/run_dashboard_format.dart';
import '../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';

/// Cockpit "Sky Context" panel — where the target sits in the sky right now,
/// plus the moon and darkness window that frame the night.
///
/// Active target: altitude (color-graded against the effective horizon like
/// `cockpit_now_imaging`), azimuth, airmass, time-to-transit / time-to-set,
/// moon illumination + phase, and time remaining until astronomical dawn.
///
/// Idle: a slim single row that still earns its place — tonight's astro-dark
/// window and the moon illumination.
///
/// Reads [runDashboardActiveTargetProvider] / [runDashboardSkyStatsProvider]
/// for target geometry and the planetarium [twilightTimesProvider],
/// [moonInfoProvider], [observationTimeProvider] for the night frame. Never
/// throws on nulls — every readout degrades to `—`.
class CockpitSkyContext extends ConsumerWidget {
  const CockpitSkyContext({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final target = ref.watch(runDashboardActiveTargetProvider);

    // `null` when no observing site is on record: the darkness window and the
    // astro-dark countdown are facts about a place, and this panel sits on the
    // same Dashboard as the Tonight card, so it must not answer where that one
    // stays silent. Moon phase/illumination are global and stay.
    final twilight = ref.watch(siteTwilightTimesProvider);
    final moon = ref.watch(moonInfoProvider);
    // The status bar, the header chip and the night timeline all render
    // Settings → Location → Timezone; this panel shares a screen with them, so
    // an astro-dark window left on host time would put two zones side by side
    // and neither would be labelled.
    final clock = ref.watch(clockProvider);

    if (target == null) {
      return _Shell(
        colors: colors,
        child: Row(
          children: [
            Icon(LucideIcons.orbit, size: 15, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                _idleSummary(twilight, moon, clock),
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // Watched only on the active-target path: the idle row doesn't use `now`,
    // so it shouldn't rebuild on the planetarium clock's 1 s tick.
    final now = ref.watch(observationTimeProvider.select((s) => s.time));
    final sky = ref.watch(runDashboardSkyStatsProvider);
    final altText =
        sky != null ? '${sky.altitudeDeg.toStringAsFixed(1)}°' : '—';
    final altColor =
        sky == null ? colors.textMuted : _altitudeColor(sky, colors);
    final azText = sky != null ? '${sky.azimuthDeg.toStringAsFixed(0)}°' : '—';
    final airmassText = sky != null ? _airmass(sky.altitudeDeg) : '—';

    final darkRemaining = _darknessRemaining(twilight, now);

    return _Shell(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.orbit, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'SKY CONTEXT',
                style:
                    SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Wrap(
            spacing: SkotiqTokens.spaceLg,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              _StatTile(
                colors: colors,
                icon: LucideIcons.mountain,
                label: 'Altitude',
                value: altText,
                valueColor: altColor,
              ),
              _StatTile(
                colors: colors,
                icon: LucideIcons.compass,
                label: 'Azimuth',
                value: azText,
              ),
              _StatTile(
                colors: colors,
                icon: LucideIcons.layers,
                label: 'Airmass',
                value: airmassText,
              ),
              _StatTile(
                colors: colors,
                icon: LucideIcons.timer,
                label: 'To meridian',
                value: formatDuration(sky?.timeToTransit),
              ),
              _StatTile(
                colors: colors,
                icon: LucideIcons.sunset,
                label: 'To set',
                value: formatDuration(sky?.timeToSet),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Divider(height: 1, color: colors.border),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Wrap(
            spacing: SkotiqTokens.spaceLg,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              _StatTile(
                colors: colors,
                icon: LucideIcons.moonStar,
                label: moon.phaseName,
                value: '${moon.illumination.toStringAsFixed(0)}%',
              ),
              _StatTile(
                colors: colors,
                icon: LucideIcons.moon,
                label: 'Astro dark left',
                value: formatDuration(darkRemaining),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Idle summary: astro-dark window + moon illumination.
  ///
  /// A null [twilight] is "no site on record" and asks for one; null dusk/dawn
  /// on a real site is polar day/night, which is unavailability, not ignorance.
  String _idleSummary(TwilightTimes? twilight, MoonTimes moon, Clock clock) {
    final dusk = twilight?.astronomicalDusk;
    final dawn = twilight?.astronomicalDawn;
    final String window;
    if (twilight == null) {
      window = 'set an observing location';
    } else if (dusk != null && dawn != null) {
      window = 'astro dark ${formatTimeOfDay(clock.fromUtc(dusk.toUtc()))}'
          '→${formatTimeOfDay(clock.fromUtc(dawn.toUtc()))}';
    } else {
      window = 'astro dark unavailable';
    }
    return 'No target — $window · Moon ${moon.illumination.toStringAsFixed(0)}%';
  }
}

/// Airmass via the secant approximation: sec(zenith) = 1/cos(z). Returns `—`
/// when the target is at or below ~3° (where plane-parallel airmass blows up
/// and is meaningless anyway).
String _airmass(double altitudeDeg) {
  if (altitudeDeg <= 3.0) return '—';
  final zenithRad = (90.0 - altitudeDeg) * math.pi / 180.0;
  final airmass = 1.0 / math.cos(zenithRad);
  return airmass.toStringAsFixed(2);
}

/// Time remaining until astronomical dawn, or `null` when there is no site,
/// dawn is unknown, or dawn is already past (so the readout shows `—`).
Duration? _darknessRemaining(TwilightTimes? twilight, DateTime now) {
  final dawn = twilight?.astronomicalDawn;
  if (dawn == null) return null;
  if (!dawn.isAfter(now)) return null;
  return dawn.difference(now);
}

/// Grade altitude against the effective horizon, matching `cockpit_now_imaging`:
/// below the horizon is error, within a 15°-clamped margin is warning, above is
/// success.
Color _altitudeColor(RunDashboardSkyStats sky, SkotiqColors colors) {
  final horizon = sky.horizonDeg;
  if (sky.altitudeDeg <= horizon) return colors.error;
  final margin =
      (90.0 - horizon) * 0.25 < 15.0 ? (90.0 - horizon) * 0.25 : 15.0;
  if (sky.altitudeDeg < horizon + margin) return colors.warning;
  return colors.success;
}

/// Compact label-over-value stat tile with tabular figures.
class _StatTile extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatTile({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              label,
              style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.sectionTitle
                .copyWith(color: valueColor ?? colors.textPrimary),
          ),
        ),
      ],
    );
  }
}

/// Self-chromed container matching the cockpit card styling.
class _Shell extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  const _Shell({required this.colors, required this.child});

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceLg,
          vertical: SkotiqTokens.spaceMd,
        ),
        child: child);
  }
}
