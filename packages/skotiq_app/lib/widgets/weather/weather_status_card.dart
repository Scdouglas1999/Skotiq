import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../tutorial_keys/weather_keys.dart';

/// The radar's own verdict, inside the Weather screen's conditions HUD.
///
/// It carries no container of its own: the caller decides whether this sits in
/// [Glass] over the map or in a [SkotiqPanel] under it, so there is one
/// block rendered two ways rather than two blocks (02 rule 4).
class WeatherStatusCard extends StatelessWidget {
  /// Current weather alert (if any)
  final WeatherAlert? alert;

  /// Cloud motion data (if available)
  final CloudMotion? motion;

  /// Last data update time
  final DateTime? lastUpdate;

  const WeatherStatusCard({
    super.key,
    this.alert,
    this.motion,
    this.lastUpdate,
  });

  /// Icon for an alert level.
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

  /// Colour for an alert level.
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

  /// Text label for an alert level.
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

  /// Format ETA duration.
  static String _formatEta(Duration eta) {
    final minutes = eta.inMinutes;
    if (minutes < 2) return 'Imminent';
    if (minutes < 60) return '~$minutes min';
    final hours = eta.inHours;
    return '~${hours}h ${minutes % 60}m';
  }

  /// Convert degrees to a cardinal direction.
  static String _degreesToCardinal(double degrees) {
    final normalized = degrees % 360;
    const directions = [
      'N',
      'NNE',
      'NE',
      'ENE',
      'E',
      'ESE',
      'SE',
      'SSE',
      'S',
      'SSW',
      'SW',
      'WSW',
      'W',
      'WNW',
      'NW',
      'NNW',
    ];
    return directions[((normalized + 11.25) / 22.5).floor() % 16];
  }

  /// Format last update time as relative.
  static String _formatLastUpdate(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inSeconds < 60) return '${difference.inSeconds} sec ago';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hr ago';
    return '${difference.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Default to clear if no alert
    final level = alert?.level ?? AlertLevel.clear;
    final tone = _alertColor(level, colors);
    final eta = alert?.eta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(_alertIcon(level), size: SkotiqTokens.iconSm, color: tone),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                _alertLabel(level),
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
            key: WeatherTutorialKeys.cloudMotion,
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
                    value: _degreesToCardinal(motion!.directionDegrees),
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
        // Null means no fetch has landed yet — say so instead of leaving the
        // slot blank; an age is only printable once there is a real fetch time
        // to age from.
        Text(
          lastUpdate == null
              ? 'Waiting for weather data'
              : 'Updated ${_formatLastUpdate(lastUpdate!)}',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}
