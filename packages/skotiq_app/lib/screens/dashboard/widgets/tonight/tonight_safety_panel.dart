// Safety & events — Tonight's c4 tile, row 2 (06 §Tonight).
//
// A `KeyValueList` of the conditions, a hairline, then the three most recent
// run events with mono timestamps.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../../sequencer/widgets/run_dashboard/weather_safety_card.dart'
    show RunDashboardSafetyBadge, runDashboardSafetyBadge;

/// How many events the panel shows (06 §Tonight: three `ListRow`s).
const int _eventCount = 3;

class TonightSafetyPanel extends ConsumerWidget {
  const TonightSafetyPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    final safety = ref.watch(weatherSafetyProvider);
    final weather = ref.watch(weatherStateProvider);
    final events = ref.watch(runDashboardRecentEventsProvider(_eventCount));

    // The badge, not the raw status: `WeatherSafetyStatus.safe` also stands for
    // "nothing was assessed", and rendering that as a green "Safe" is the most
    // glanceable lie this panel can tell.
    final badge = runDashboardSafetyBadge(
      status: safety.status,
      monitoringEnabled: safety.monitoringEnabled,
      dataSource: safety.dataSource,
    );

    final (String label, ChipTone tone) = switch (badge) {
      RunDashboardSafetyBadge.safe => (
          l10n.text('tnSafe'),
          ChipTone.success,
        ),
      RunDashboardSafetyBadge.unsafe => (
          l10n.text('tnUnsafe'),
          ChipTone.error,
        ),
      RunDashboardSafetyBadge.snoozed => (
          l10n.text('tnSnoozed'),
          ChipTone.warning,
        ),
      RunDashboardSafetyBadge.notMonitored => (
          l10n.text('tnNotMonitored'),
          ChipTone.neutral,
        ),
      RunDashboardSafetyBadge.noData => (
          l10n.text('tnNoWeatherData'),
          ChipTone.warning,
        ),
    };

    final dewMargin = (weather.temperature != null && weather.dewPoint != null)
        ? weather.temperature! - weather.dewPoint!
        : null;

    return SkotiqPanel(
      head: PanelHead(
        icon: LucideIcons.shieldCheck,
        label: l10n.text('tnSafetyEvents'),
        trailing: <Widget>[SkotiqChip(label: label, tone: tone)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          KeyValueList(
            rows: <(String, String)>[
              (
                l10n.text('tnClouds'),
                weather.cloudCover == null
                    ? kReadoutUnknown
                    : '${weather.cloudCover!.round()}%',
              ),
              (
                l10n.text('tnWind'),
                weather.windSpeedKph == null
                    ? kReadoutUnknown
                    : '${weather.windSpeedKph!.round()} km/h',
              ),
              (
                l10n.text('tnDewPoint'),
                weather.dewPoint == null
                    ? kReadoutUnknown
                    : '${weather.dewPoint!.toStringAsFixed(1)}°C'
                        '${dewMargin == null ? '' : ' · ${dewMargin.toStringAsFixed(1)}° '
                            '${l10n.text('tnMargin')}'}',
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Divider(height: 1, thickness: 1, color: colors.border),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: SkotiqTokens.spaceSm,
              ),
              child: Text(
                l10n.text('tnNoEvents'),
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            )
          else
            for (var i = 0; i < events.length; i++)
              ListRow(
                icon: _eventIcon(events[i].severity),
                title: events[i].title,
                trailing: _time(events[i].time),
                showDivider: i < events.length - 1,
              ),
        ],
      ),
    );
  }

  static IconData _eventIcon(RunDashboardEventSeverity severity) {
    return switch (severity) {
      RunDashboardEventSeverity.info => LucideIcons.info,
      RunDashboardEventSeverity.warning => LucideIcons.alertTriangle,
      RunDashboardEventSeverity.error => LucideIcons.alertCircle,
      RunDashboardEventSeverity.critical => LucideIcons.alertOctagon,
    };
  }

  static String _time(DateTime at) {
    final local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
