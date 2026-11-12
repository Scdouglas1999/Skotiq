import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../tours/tour_target.dart';

/// The radar's own verdict, inside the Weather screen's conditions HUD.
///
/// It carries no container of its own: the caller decides whether this sits in
/// [Glass] over the map or in a [SkotiqPanel] under it, so there is one
/// block rendered two ways rather than two blocks (02 rule 4).
class WeatherStatusCard extends StatelessWidget {
  final WeatherAlert? alert;

  final CloudMotion? motion;

  /// When the last fetch that returned data finished.
  final DateTime? lastUpdate;

  /// The latest attempt to fetch weather data failed. Anything still shown
  /// is from [lastUpdate], not from now.
  final bool fetchFailed;

  const WeatherStatusCard({
    super.key,
    this.alert,
    this.motion,
    this.lastUpdate,
    this.fetchFailed = false,
  });

  static IconData _alertIcon(AlertLevel level) {
    switch (level) {
      case AlertLevel.clear:
        return SkotiqIcons.success;
      case AlertLevel.watch:
        return SkotiqIcons.visible;
      case AlertLevel.warning:
        return SkotiqIcons.warning;
      case AlertLevel.critical:
        return SkotiqIcons.error;
    }
  }

  static Color _alertColor(AlertLevel level, SkotiqColors colors) {
    switch (level) {
      case AlertLevel.clear:
        return colors.success;
      case AlertLevel.watch:
      case AlertLevel.warning:
        return colors.warning;
      case AlertLevel.critical:
        return colors.error;
    }
  }

  static String _alertLabel(AlertLevel level) {
    switch (level) {
      case AlertLevel.clear:
        return 'Clear';
      case AlertLevel.watch:
        return 'Watch';
      case AlertLevel.warning:
        return 'Warning';
      case AlertLevel.critical:
        return 'Critical';
    }
  }

  static String _formatEta(Duration eta) => eta.inMinutes < 2
      ? 'Imminent'
      : '~${DurationFormat.of(eta, style: DurationStyle.coarse)}';


  static String _formatLastUpdate(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inSeconds < 60) return '${difference.inSeconds} sec ago';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hr ago';
    return '${difference.inDays} days ago';
  }

  /// How old the data on the card is, or why there is none. A reading with no
  /// fetch time to age it gets no line rather than a made-up one.
  String? _freshnessLine() {
    if (lastUpdate != null) {
      final age = _formatLastUpdate(lastUpdate!);
      return fetchFailed ? 'Last data $age' : 'Updated $age';
    }
    if (alert != null) return null;
    return fetchFailed ? 'No weather data received' : 'Waiting for weather data';
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final level = alert?.level;
    // A level from before a failed fetch is history, so it loses its status
    // color; with no level at all there is nothing to call clear.
    final tone = level == null || fetchFailed
        ? colors.textMuted
        : _alertColor(level, colors);
    final eta = fetchFailed ? null : alert?.eta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              level == null ? SkotiqIcons.help : _alertIcon(level),
              size: SkotiqTokens.iconSm,
              color: tone,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                level != null
                    ? _alertLabel(level)
                    : fetchFailed
                        ? 'Unknown'
                        : 'Checking',
                style: SkotiqTypography.bodyStrong.copyWith(color: tone),
              ),
            ),
            if (eta != null)
              Readout(
                value: _formatEta(eta.difference(DateTime.now())),
                label: 'Arrives',
                size: ReadoutSize.sm,
                valueColor: tone,
              ),
          ],
        ),
        if (alert != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            alert!.message,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
        if (motion != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          // Two rows of two, not one row of four: "12.5 km/h" needs ~76 px at
          // `readoutSm` and a 300 px HUD gives four readouts ~54 px each, which
          // ellipsizes the unit off the number it belongs to.
          Column(
            key: TourTarget.weatherCloudMotion.key,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ReadoutRow(
                gap: SkotiqTokens.spaceXl,
                children: [
                  Readout(
                    value: motion!.speedKmh.toStringAsFixed(1),
                    unit: 'km/h',
                    label: 'Speed',
                    size: ReadoutSize.sm,
                  ),
                  Readout(
                    value: AngleFormat.compass(motion!.directionDegrees, points: 8),
                    label: 'Toward',
                    size: ReadoutSize.sm,
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              ReadoutRow(
                gap: SkotiqTokens.spaceXl,
                children: [
                  Readout(
                    value: motion!.distanceKm.toStringAsFixed(1),
                    unit: 'km',
                    label: 'Distance',
                    size: ReadoutSize.sm,
                  ),
                  Readout(
                    value: alert?.cloudDensityPercent.toStringAsFixed(0),
                    unit: '%',
                    label: 'Density',
                    size: ReadoutSize.sm,
                  ),
                ],
              ),
            ],
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (_freshnessLine() case final line?)
          Text(
            line,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
      ],
    );
  }
}
