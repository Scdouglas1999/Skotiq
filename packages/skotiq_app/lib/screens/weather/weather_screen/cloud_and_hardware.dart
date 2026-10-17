part of '../weather_screen.dart';

/// The conditions HUD.
///
/// One block, used twice: floated in [Glass] over the radar on a desktop-width
/// window, and dropped into a [SkotiqPanel] under the map when the window
/// is too narrow for a floating panel or when there is no site and therefore no
/// radar to float over. Same widgets either way — there is one of everything
/// (02 rule 4).
class _WeatherConditions extends ConsumerWidget {
  /// Whether the radar-derived figures (cloud cover, alert level, motion) have
  /// a site to have been measured for. Without one only the hardware sensors
  /// and the safety verdict are real.
  final bool radarAvailable;

  final WeatherAlert? alert;
  final CloudMotion? motion;
  final DateTime? lastUpdate;
  final double? cloudCoverPercent;
  final double? alertRadiusKm;
  final bool expanded;
  final VoidCallback? onExpandToggle;

  const _WeatherConditions({
    super.key,
    this.radarAvailable = false,
    required this.alert,
    required this.motion,
    required this.lastUpdate,
    required this.cloudCoverPercent,
    required this.alertRadiusKm,
    required this.expanded,
    this.onExpandToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final weatherState = ref.watch(weatherStateProvider);
    final safetyDeviceState = ref.watch(safetyMonitorStateProvider);
    final settings = ref.watch(weatherSettingsProvider);
    final safetyState = ref.watch(weatherSafetyProvider);

    final hasWeatherDevice =
        weatherState.connectionState == DeviceConnectionState.connected;
    final hasSafetyDevice =
        safetyDeviceState.connectionState == DeviceConnectionState.connected;

    final sensorRows = <(String, String)>[
      if (hasSafetyDevice)
        (
          safetyDeviceState.deviceName ?? 'Safety monitor',
          safetyDeviceState.isSafe ? 'Safe' : 'Unsafe',
        ),
      if (hasWeatherDevice) ...[
        if (weatherState.temperature != null)
          ('Temperature', '${weatherState.temperature!.toStringAsFixed(1)} °C'),
        if (weatherState.humidity != null)
          ('Humidity', '${weatherState.humidity!.toStringAsFixed(0)} %'),
        if (weatherState.dewPoint != null)
          ('Dew point', '${weatherState.dewPoint!.toStringAsFixed(1)} °C'),
        if (weatherState.windSpeed != null)
          ('Wind', '${weatherState.windSpeed!.toStringAsFixed(1)} m/s'),
        if (weatherState.cloudCover != null)
          ('Sensor cloud', '${weatherState.cloudCover!.toStringAsFixed(0)} %'),
        if (weatherState.skyQuality != null)
          (
            'Sky quality',
            // "mag/arcsec²", spelled out: the squared-arcsecond glyph is not
            // in Spline Sans Mono and rendered as a tofu box on screen.
            '${weatherState.skyQuality!.toStringAsFixed(2)} mag/arcsec²',
          ),
        if (weatherState.rainRate != null && weatherState.rainRate! > 0)
          ('Rain', '${weatherState.rainRate!.toStringAsFixed(1)} mm/hr'),
        if (weatherState.lastUpdated != null)
          ('Updated', _relativeAge(weatherState.lastUpdated!)),
      ],
    ];

    final showHeadline =
        radarAvailable && (cloudCoverPercent != null || alertRadiusKm != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeadline)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ReadoutRow(
                  gap: SkotiqTokens.space2xl,
                  children: [
                    Readout(
                      value: cloudCoverPercent?.toStringAsFixed(0),
                      unit: '%',
                      label: 'Cloud cover',
                      valueColor: _cloudCoverTone(colors, cloudCoverPercent),
                    ),
                    Readout(
                      key: WeatherTutorialKeys.alertRadius,
                      value: alertRadiusKm?.toStringAsFixed(0),
                      unit: 'km',
                      label: 'Alert radius',
                      size: ReadoutSize.sm,
                    ),
                  ],
                ),
              ),
              if (onExpandToggle != null)
                SkotiqIconButton(
                  icon: expanded
                      ? SkotiqIcons.chevronUp
                      : SkotiqIcons.chevronDown,
                  tooltip: expanded ? 'Collapse conditions' : 'Show conditions',
                  size: IconButtonSize.sm,
                  onPressed: onExpandToggle,
                ),
            ],
          ),
        if (expanded) ...[
          if (radarAvailable) ...[
            if (showHeadline) const SizedBox(height: SkotiqTokens.spaceMd),
            WeatherStatusCard(
              alert: alert,
              motion: motion,
              lastUpdate: lastUpdate,
            ),
          ],
          if (sensorRows.isNotEmpty) ...[
            const _ConditionsDivider(),
            const _ConditionsEyebrow(label: 'Sensors'),
            KeyValueList(rows: sensorRows),
          ],
          const _ConditionsDivider(),
          KeyValueList(
            rows: [
              (
                'Auto-park',
                weatherPolicyArmedLabel(
                  armed: safetyState.autoParkArmed,
                  toggledOn: settings.autoParkEnabled,
                ),
              ),
              (
                'Auto-resume',
                weatherPolicyArmedLabel(
                  armed: safetyState.autoResumeArmed,
                  toggledOn: settings.autoResumeEnabled,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          const _SafetyDisclosure(),
        ],
      ],
    );
  }

  /// The cloud-cover value carries status, so it takes a status colour: a
  /// clear sky is `success`, an overcast one is `error`.
  static Color? _cloudCoverTone(SkotiqColors colors, double? percent) {
    if (percent == null) return null;
    if (percent <= 25) return colors.success;
    if (percent <= 60) return colors.warning;
    return colors.error;
  }
}

/// A hairline between blocks inside the conditions HUD.
class _ConditionsDivider extends StatelessWidget {
  const _ConditionsDivider();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: SkotiqTokens.spaceMd,
      ),
      child: Container(height: 1, color: colors.border),
    );
  }
}

/// An 11px uppercase group label inside the conditions HUD. A [PanelHead] is
/// for a panel; this is the same label at the same weight, one level in.
class _ConditionsEyebrow extends StatelessWidget {
  final String label;

  const _ConditionsEyebrow({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: Text(
        label.toUpperCase(),
        style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
      ),
    );
  }
}

/// "just now" / "3m ago" / "2h ago".
String _relativeAge(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  return '${diff.inHours}h ago';
}
