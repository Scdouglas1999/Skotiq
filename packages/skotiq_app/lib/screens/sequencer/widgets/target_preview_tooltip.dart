import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Provider for target altitude data
// autoDispose: this is a .family provider keyed by TargetHeaderNode — without
// autoDispose each unique target hovered would leave a permanent
// FutureProvider instance in the container, growing memory unboundedly.
// Tooltip lifetime is the natural scope for these computations.
final targetAltitudeProvider = FutureProvider.autoDispose
    .family<TargetAltitudeInfo?, TargetHeaderNode>((ref, target) async {
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  if (settings == null) return null;

  final lat = settings.latitude;
  final lon = settings.longitude;

  if (lat == 0.0 && lon == 0.0) {
    // No location set
    return null;
  }

  final now = DateTime.now().toUtc();

  // TargetHeaderNode stores RA in hours; AstronomyCalculations works in
  // degrees, so convert raHours * 15 once and reuse it everywhere.
  final raDeg = target.raHours * 15.0;
  final decDeg = target.decDegrees;
  final minAlt = target.minAltitude ?? 0;

  // Current alt/az via the shared astronomy library (no bespoke math).
  final (currentAlt, azimuth) = AstronomyCalculations.objectAltAz(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: now,
    latitudeDeg: lat,
    longitudeDeg: lon,
  );

  // Rising vs setting: compare against the altitude 10 minutes from now.
  final (futureAlt, _) = AstronomyCalculations.objectAltAz(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: now.add(const Duration(minutes: 10)),
    latitudeDeg: lat,
    longitudeDeg: lon,
  );
  final isRising = futureAlt > currentAlt;

  // Transit time/altitude and hours-above-horizon via the same visibility
  // model the scheduler and queue panel use.
  final visibility = AstronomyCalculations.calculateObjectVisibility(
    raDeg: raDeg,
    decDeg: decDeg,
    // The NIGHT containing [now] — after local midnight the raw instant names
    // tomorrow, so transit and hours-above-horizon described the next night.
    date: AstronomyCalculations.nightDateOf(now),
    latitudeDeg: lat,
    longitudeDeg: lon,
    minAltitude: minAlt,
  );

  final transitTime = visibility.transitTime ?? now;
  final transitAlt = visibility.transitAltitude ?? currentAlt;
  final hoursAbove =
      (visibility.durationAboveHorizon ?? Duration.zero).inMinutes / 60.0;

  return TargetAltitudeInfo(
    currentAltitude: currentAlt,
    azimuth: azimuth,
    isRising: isRising,
    transitTime: transitTime,
    transitAltitude: transitAlt,
    hoursAboveHorizon: hoursAbove,
  );
});

/// Data class for target altitude info
class TargetAltitudeInfo {
  final double currentAltitude;
  final double azimuth;
  final bool isRising;
  final DateTime transitTime;
  final double transitAltitude;
  final double hoursAboveHorizon;

  const TargetAltitudeInfo({
    required this.currentAltitude,
    required this.azimuth,
    required this.isRising,
    required this.transitTime,
    required this.transitAltitude,
    required this.hoursAboveHorizon,
  });
}

/// Target preview tooltip widget
class TargetPreviewTooltip extends ConsumerWidget {
  final TargetHeaderNode target;
  final SkotiqColors colors;
  final Widget child;

  const TargetPreviewTooltip({
    super.key,
    required this.target,
    required this.colors,
    required this.child,
  });

  String _formatRA(double raHours) => CoordinateFormat.ra(
        raHours,
        style: SexagesimalStyle.plainLetters,
        seconds: SecondsPrecision.integerFloored,
      );

  String _formatDec(double decDegrees) => CoordinateFormat.dec(
        decDegrees,
        style: SexagesimalStyle.plainLetters,
        seconds: SecondsPrecision.integerFloored,
      );

  /// Transit is a fact about the OBSERVING SITE, so it reads in the site's
  /// zone (Settings → Location → Timezone), not the controlling laptop's.
  /// [SystemClock.fromUtc] is `toLocal()`, so "use system time" is unchanged.
  String _formatTime(DateTime time, Clock clock) {
    final shown = clock.fromUtc(time.toUtc());
    final hour = shown.hour.toString().padLeft(2, '0');
    final minute = shown.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final altitudeData = ref.watch(targetAltitudeProvider(target));

    return Tooltip(
      richMessage: WidgetSpan(
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            border: Border.all(color: colors.border),
            boxShadow: [
              BoxShadow(
                // absolute: drop-shadow scrim (theme-independent)
                color: ImageOverlayColors.shadow.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: SkotiqDecorations.statusChip(
                      colors.warning,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                      bordered: false,
                    ),
                    child: Icon(
                      LucideIcons.target,
                      size: 16,
                      color: colors.warning,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          target.targetName,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize14,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        if (target.priority > 0)
                          Text(
                            'Priority: ${target.priority}',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize10,
                              color: colors.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),
              Divider(height: 1, color: colors.border),
              const SizedBox(height: 12),

              // Coordinates
              _InfoRow(
                colors: colors,
                icon: LucideIcons.compass,
                label: 'RA',
                value: _formatRA(target.raHours),
              ),
              const SizedBox(height: 6),
              _InfoRow(
                colors: colors,
                icon: LucideIcons.compass,
                label: 'Dec',
                value: _formatDec(target.decDegrees),
              ),

              if (target.rotation != null) ...[
                const SizedBox(height: 6),
                _InfoRow(
                  colors: colors,
                  icon: LucideIcons.rotateCw,
                  label: 'Rotation',
                  value: '${target.rotation!.toStringAsFixed(1)}°',
                ),
              ],

              // Altitude data
              altitudeData.when(
                data: (data) {
                  if (data == null) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Set observer location for altitude data',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize10,
                          fontStyle: FontStyle.italic,
                          color: colors.textMuted,
                        ),
                      ),
                    );
                  }

                  final isAboveHorizon = data.currentAltitude > 0;
                  final altColor = data.currentAltitude < 20
                      ? colors.error
                      : data.currentAltitude < 40
                          ? colors.warning
                          : colors.success;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      Divider(height: 1, color: colors.border),
                      const SizedBox(height: 12),

                      // Current position
                      Row(
                        children: [
                          Expanded(
                            child: _InfoRow(
                              colors: colors,
                              icon: LucideIcons.mountainSnow,
                              label: 'Alt',
                              value:
                                  '${data.currentAltitude.toStringAsFixed(1)}°',
                              valueColor: altColor,
                            ),
                          ),
                          Expanded(
                            child: _InfoRow(
                              colors: colors,
                              icon: LucideIcons.compass,
                              label: 'Az',
                              value: '${data.azimuth.toStringAsFixed(1)}°',
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      // Status badges
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _StatusBadge(
                            colors: colors,
                            icon: data.isRising
                                ? LucideIcons.trendingUp
                                : LucideIcons.trendingDown,
                            label: data.isRising ? 'Rising' : 'Setting',
                            color:
                                data.isRising ? colors.success : colors.warning,
                          ),
                          if (!isAboveHorizon)
                            _StatusBadge(
                              colors: colors,
                              icon: LucideIcons.moonStar,
                              label: 'Below horizon',
                              color: colors.error,
                            ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Transit info
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colors.surfaceAlt,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.clock,
                              size: 14,
                              color: colors.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Transit: '
                                    '${_formatTime(data.transitTime, ref.watch(clockProvider))}',
                                    style: SkotiqTypography.labelStrongSm
                                        .copyWith(color: colors.textPrimary),
                                  ),
                                  Text(
                                    'Max altitude: ${data.transitAltitude.toStringAsFixed(1)}°',
                                    style: TextStyle(
                                      fontSize: SkotiqTypography.fontSize10,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (data.hoursAboveHorizon > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 3),
                                decoration: SkotiqDecorations.statusChip(
                                  colors.primary,
                                  borderRadius: BorderRadius.circular(
                                      SkotiqTokens.radiusInline4),
                                  bordered: false,
                                ),
                                child: Text(
                                  '${data.hoursAboveHorizon.toStringAsFixed(1)}h',
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize10,
                                    fontWeight: FontWeight.w600,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      // Constraints
                      if (target.minAltitude != null ||
                          target.maxAltitude != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              LucideIcons.sliders,
                              size: 12,
                              color: colors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Constraints: ',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize10,
                                color: colors.textMuted,
                              ),
                            ),
                            if (target.minAltitude != null)
                              Text(
                                'Min ${target.minAltitude!.toStringAsFixed(0)}°',
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize10,
                                  color: colors.textSecondary,
                                ),
                              ),
                            if (target.minAltitude != null &&
                                target.maxAltitude != null)
                              Text(
                                ' - ',
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize10,
                                  color: colors.textMuted,
                                ),
                              ),
                            if (target.maxAltitude != null)
                              Text(
                                'Max ${target.maxAltitude!.toStringAsFixed(0)}°',
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize10,
                                  color: colors.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  );
                },
                loading: () => Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: SkotiqSpinner(size: 16, color: colors.textMuted),
                    ),
                  ),
                ),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
      waitDuration: const Duration(milliseconds: 400),
      showDuration: const Duration(seconds: 10),
      preferBelow: false,
      child: child,
    );
  }
}

class _InfoRow extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 12, color: colors.textMuted),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            fontWeight: FontWeight.w600,
            color: valueColor ?? colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final Color color;

  const _StatusBadge({
    required this.colors,
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: SkotiqDecorations.statusChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
