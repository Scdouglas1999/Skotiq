import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard_format.dart';

/// What the header pill is entitled to claim about the sky.
///
/// [WeatherSafetyStatus] alone cannot answer this: it collapses "a sensor
/// reported safe conditions" and "nothing was assessed, so there is no verdict
/// to report" into the same `safe` value (see the doc on
/// `WeatherSafetyState.monitoringEnabled`). Rendering that collapse as a green
/// "Safe" is the single most glanceable lie this card can tell, so the two
/// unassessed cases get their own states.
enum RunDashboardSafetyBadge { safe, unsafe, snoozed, notMonitored, noData }

/// Derive the pill state from the whole safety snapshot, not just its status.
///
/// Top-level so the claim is testable without building the provider graph.
RunDashboardSafetyBadge runDashboardSafetyBadge({
  required WeatherSafetyStatus status,
  required bool monitoringEnabled,
  required SafetyDataSource dataSource,
}) {
  // Master switch off: nothing is evaluated at all, whatever `status` says.
  if (!monitoringEnabled) return RunDashboardSafetyBadge.notMonitored;
  switch (status) {
    case WeatherSafetyStatus.unsafe:
      return RunDashboardSafetyBadge.unsafe;
    case WeatherSafetyStatus.snoozed:
      return RunDashboardSafetyBadge.snoozed;
    case WeatherSafetyStatus.safe:
      // A permissive fail mode resolves no-data to `safe` so the run keeps
      // going; that is an operational decision, not a measurement, and the
      // pill must not present it as one.
      return dataSource == SafetyDataSource.unavailable
          ? RunDashboardSafetyBadge.noData
          : RunDashboardSafetyBadge.safe;
  }
}

/// Read-only weather/safety snapshot for the Run dashboard.
///
/// Surfaces the same `weatherSafetyProvider` state already evaluated by the
/// sequencer's safety subsystem — never re-evaluates conditions on its own.
class RunDashboardWeatherSafetyCard extends ConsumerWidget {
  const RunDashboardWeatherSafetyCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final safety = ref.watch(weatherSafetyProvider);

    final badge = runDashboardSafetyBadge(
      status: safety.status,
      monitoringEnabled: safety.monitoringEnabled,
      dataSource: safety.dataSource,
    );

    final (statusText, statusColor, statusIcon) = switch (badge) {
      RunDashboardSafetyBadge.safe => (
          'Safe',
          colors.success,
          LucideIcons.check
        ),
      RunDashboardSafetyBadge.unsafe => (
          'Unsafe',
          colors.error,
          LucideIcons.alertTriangle
        ),
      RunDashboardSafetyBadge.snoozed => (
          'Snoozed',
          colors.warning,
          LucideIcons.bellOff
        ),
      RunDashboardSafetyBadge.notMonitored => (
          'Not monitored',
          colors.textMuted,
          LucideIcons.shieldOff
        ),
      RunDashboardSafetyBadge.noData => (
          'No data',
          colors.warning,
          LucideIcons.helpCircle
        ),
    };

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.shield, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'SAFETY',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: colors.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              // Use Flexible around the pill so a narrow column doesn't
              // overflow when the status label is long ("Snoozed" + icon
              // pushes past the cell width on a 280px viewport).
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: SkotiqDecorations.statusChip(
                    statusColor,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusXs),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 11, color: statusColor),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          statusText,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize10,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                            letterSpacing: 0.4,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _SourceRow(
            colors: colors,
            label: 'Data',
            value: _sourceLabel(safety.dataSource),
          ),
          if (safety.lastEvaluation != null)
            _SourceRow(
              colors: colors,
              label: 'As of',
              value: formatTimeOfDay(safety.lastEvaluation!.toLocal()),
              // Grade the row stale once the snapshot is older than ~2x the
              // 5-minute safety evaluation interval, mirroring the adaptive
              // panel's staleness cue so a frozen weather feed is visible.
              valueColor: _staleColor(safety.lastEvaluation!, colors),
            ),
          _LiveConditions(colors: colors),
          if (safety.failModeWarning != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Container(
              padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
              decoration: SkotiqDecorations.emphasisSurface(
                colors.warning,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.alertTriangle,
                      size: 12, color: colors.warning),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      safety.failModeWarning!,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (safety.actions.reason != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              safety.actions.reason!,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary,
              ),
            ),
          ],
          if (safety.snoozeUntil != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _SourceRow(
              colors: colors,
              label: 'Snooze until',
              value: formatTimeOfDay(safety.snoozeUntil!.toLocal()),
            ),
          ],
        ],
      ),
    );
  }

  /// Grade the "As of" timestamp: warning past ~2x the 5-minute evaluation
  /// interval, error past ~4x — a hard signal that the safety feed has gone
  /// quiet and the displayed numbers may be stale.
  Color? _staleColor(DateTime lastEvaluation, SkotiqColors colors) {
    final age = DateTime.now().difference(lastEvaluation);
    if (age >= const Duration(minutes: 20)) return colors.error;
    if (age >= const Duration(minutes: 10)) return colors.warning;
    return null;
  }

  String _sourceLabel(SafetyDataSource src) {
    switch (src) {
      case SafetyDataSource.weatherApi:
        return 'Weather API';
      case SafetyDataSource.hardwareWeather:
        return 'Hardware sensor';
      case SafetyDataSource.safetyMonitor:
        return 'Safety monitor';
      case SafetyDataSource.combined:
        return 'Combined';
      case SafetyDataSource.unavailable:
        return 'Unavailable';
    }
  }
}

/// Live numeric conditions from the connected hardware weather device,
/// colour-graded against the user's configured safety thresholds.
///
/// Renders nothing when no hardware weather device is connected — the status
/// pill and data-source row above already convey the API-only case, and
/// numbers the rig is not reporting must not be invented here.
/// Each row is shown only when its value is present; the colour grades
/// green/amber/red relative to the threshold so an operator can see headroom
/// at a glance (e.g. wind 24 km/h amber against a 30 km/h limit).
class _LiveConditions extends ConsumerWidget {
  final SkotiqColors colors;

  const _LiveConditions({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weather = ref.watch(weatherStateProvider);
    if (weather.connectionState != DeviceConnectionState.connected) {
      return const SizedBox.shrink();
    }
    final settingsAsync = ref.watch(weatherSettingsDataProvider);
    final settings = settingsAsync.valueOrNull;
    if (settings == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          settingsAsync.hasError
              ? 'Safety thresholds unavailable'
              : 'Loading safety thresholds…',
          style: SkotiqTypography.caption.copyWith(
            color: settingsAsync.hasError ? colors.error : colors.textMuted,
          ),
        ),
      );
    }

    final rows = <Widget>[];

    final cloud = weather.cloudCover;
    if (cloud != null) {
      rows.add(_ConditionRow(
        colors: colors,
        label: 'Cloud',
        value: '${cloud.toStringAsFixed(0)}%',
        valueColor: weatherGradeAscending(
          cloud,
          warnAt: settings.maxCloudCoverPercent * 0.75,
          unsafeAt: settings.maxCloudCoverPercent,
          colors: colors,
        ),
      ));
    }

    final wind = weather.windSpeedKph;
    if (wind != null) {
      rows.add(_ConditionRow(
        colors: colors,
        label: 'Wind',
        value: '${wind.toStringAsFixed(0)} km/h',
        valueColor: weatherGradeAscending(
          wind,
          warnAt: settings.maxWindSpeedKph * 0.75,
          unsafeAt: settings.maxWindSpeedKph,
          colors: colors,
        ),
      ));
    }

    final humidity = weather.humidity;
    if (humidity != null) {
      rows.add(_ConditionRow(
        colors: colors,
        label: 'Humidity',
        value: '${humidity.toStringAsFixed(0)}%',
        valueColor: weatherGradeAscending(
          humidity,
          warnAt: settings.maxHumidityPercent * 0.9,
          unsafeAt: settings.maxHumidityPercent,
          colors: colors,
        ),
      ));
    }

    // Sky-ambient ΔT: cloud sensors report sky temperature; the colder the
    // sky relative to ambient, the clearer it is. A small (near-zero or
    // positive) delta means cloud/overcast. We grade on (ambient - sky):
    // a large positive spread is good (clear), near zero is bad (cloudy).
    final ambient = weather.temperature;
    final sky = weather.skyTemperature;
    if (ambient != null && sky != null) {
      final deltaT = ambient - sky;
      rows.add(_ConditionRow(
        colors: colors,
        label: 'Sky−Amb ΔT',
        value: '${deltaT.toStringAsFixed(1)}°C',
        valueColor: weatherGradeDescending(
          deltaT,
          warnBelow: 15.0,
          unsafeBelow: 5.0,
          colors: colors,
        ),
      ));
    }

    // Dew-point spread: ambient minus dew point. A small spread means the
    // optics are close to dewing up. Grade descending — large spread good.
    final dewPoint = weather.dewPoint;
    if (ambient != null && dewPoint != null) {
      final spread = ambient - dewPoint;
      rows.add(_ConditionRow(
        colors: colors,
        label: 'Dew spread',
        value: '${spread.toStringAsFixed(1)}°C',
        valueColor: weatherGradeDescending(
          spread,
          warnBelow: 5.0,
          unsafeBelow: 2.0,
          colors: colors,
        ),
      ));
    }

    // Sky quality (SQM) in mag/arcsec²: higher is darker/better. Only some
    // weather/sky-quality devices report it. Grade descending.
    final sqm = weather.skyQuality;
    if (sqm != null) {
      rows.add(_ConditionRow(
        colors: colors,
        label: 'SQM',
        value: '${sqm.toStringAsFixed(2)} mag',
        valueColor: weatherGradeDescending(
          sqm,
          warnBelow: 20.0,
          unsafeBelow: 18.0,
          colors: colors,
        ),
      ));
    }

    final rain = weather.rainRate;
    if (rain != null) {
      rows.add(_ConditionRow(
        colors: colors,
        label: 'Rain',
        value: rain > 0 ? '${rain.toStringAsFixed(1)} mm/h' : 'None',
        valueColor: rain > 0 ? colors.error : colors.success,
      ));
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SkotiqTokens.spaceMd),
        Divider(height: 1, color: colors.border),
        const SizedBox(height: SkotiqTokens.spaceSm),
        ...rows,
      ],
    );
  }
}

/// Grade a metric where higher is worse (cloud, wind, humidity).
/// Top-level (not private) so the grading is unit-testable independent of the
/// provider graph.
Color weatherGradeAscending(
  double value, {
  required double warnAt,
  required double unsafeAt,
  required SkotiqColors colors,
}) {
  if (value >= unsafeAt) return colors.error;
  if (value >= warnAt) return colors.warning;
  return colors.success;
}

/// Grade a metric where lower is worse (sky−ambient ΔT, dew spread, SQM).
Color weatherGradeDescending(
  double value, {
  required double warnBelow,
  required double unsafeBelow,
  required SkotiqColors colors,
}) {
  if (value <= unsafeBelow) return colors.error;
  if (value <= warnBelow) return colors.warning;
  return colors.success;
}

class _ConditionRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final Color valueColor;

  const _ConditionRow({
    required this.colors,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            value,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              fontWeight: FontWeight.w700,
              color: valueColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;

  /// Optional override for the value colour — used to grade a stale "As of"
  /// timestamp. Falls back to the muted secondary tone when null.
  final Color? valueColor;

  const _SourceRow({
    required this.colors,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: SkotiqTypography.h6
              .copyWith(color: valueColor ?? colors.textSecondary),
        ),
      ],
    );
  }
}
