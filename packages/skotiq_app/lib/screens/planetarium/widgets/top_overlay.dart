import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:intl/intl.dart';
import '../../../utils/coordinate_format_utils.dart';
import '../../sequencer/widgets/run_dashboard/recovery_banner.dart';

class TopOverlay extends ConsumerWidget {
  final SkotiqColors colors;

  const TopOverlay({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(observerLocationProvider);
    final time = ref.watch(observationTimeProvider);
    // The planetarium's own readout follows the time transport, so it reads the
    // SIMULATED sidereal time — beside the simulated clock it sits next to.
    // `localSiderealTimeProvider` is the real one, for the chrome outside this
    // screen that must keep stating the truth while the sky is scrubbed.
    final lst = ref.watch(observationSiderealTimeProvider);
    final renderConfig = ref.watch(skyRenderConfigProvider);
    final settingsAsync = ref.watch(appSettingsProvider);

    // Get location name from settings if available
    // A coordinate pair here is a claim about where the operator is, so with
    // no site on record the chip says so rather than printing 0/0.
    String locationLabel;
    final settings = settingsAsync.valueOrNull;
    final site = location.site;
    if (settings != null && (settings.hasObserverLocation)) {
      locationLabel = CoordinateFormatUtils.formatLatLon(
          settings.latitude, settings.longitude);
    } else if (location.locationName != null) {
      locationLabel = location.locationName!;
    } else if (site != null) {
      locationLabel =
          CoordinateFormatUtils.formatLatLon(site.latitude, site.longitude);
    } else {
      locationLabel = 'No site set';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Recovery Mode — surface the live recovery banner at the
        // top of the planetarium screen so a user watching the sky chart
        // still sees recovery state. Empty SizedBox when not recovering.
        const RunDashboardRecoveryBanner(),
        LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 900;
            final isVeryCompact = constraints.maxWidth < 720;
            final horizontalPadding =
                isVeryCompact ? 12.0 : (isCompact ? 16.0 : 20.0);
            final chipSpacing = isVeryCompact ? 6.0 : (isCompact ? 8.0 : 12.0);
            final toggleSpacing = isVeryCompact ? 2.0 : 4.0;
            final timeFormat =
                isCompact ? DateFormat('HH:mm') : DateFormat('HH:mm:ss');

            return Container(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: isCompact ? 8 : 12,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (!isVeryCompact) ...[
                            OverlayChip(
                              icon: SkotiqIcons.location,
                              label: locationLabel,
                              colors: colors,
                              compact: isCompact,
                            ),
                            SizedBox(width: chipSpacing),
                          ],
                          OverlayChip(
                            icon: SkotiqIcons.clock,
                            label: timeFormat.format(time.time),
                            colors: colors,
                            compact: isCompact,
                          ),
                          SizedBox(width: chipSpacing),
                          OverlayChip(
                            icon: SkotiqIcons.star,
                            label: 'LST ${_formatHours(lst)}',
                            colors: colors,
                            compact: isCompact,
                          ),
                          SizedBox(width: chipSpacing),
                          SequencerStatusLed(showLabel: !isCompact),
                          if (!time.isRealTime) ...[
                            SizedBox(width: chipSpacing),
                            TimeControlButton(
                              icon: SkotiqIcons.play,
                              onTap: () => ref
                                  .read(observationTimeProvider.notifier)
                                  .setRealTime(true),
                              colors: colors,
                              compact: isCompact,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: chipSpacing),
                  OverlayToggle(
                    icon: SkotiqIcons.grid,
                    tooltip: 'Coordinate grid',
                    isActive: renderConfig.showCoordinateGrid,
                    onTap:
                        ref.read(skyRenderConfigProvider.notifier).toggleGrid,
                  ),
                  SizedBox(width: toggleSpacing),
                  OverlayToggle(
                    icon: SkotiqIcons.activity,
                    tooltip: 'Constellation lines',
                    isActive: renderConfig.showConstellationLines,
                    onTap: ref
                        .read(skyRenderConfigProvider.notifier)
                        .toggleConstellationLines,
                  ),
                  SizedBox(width: toggleSpacing),
                  if (!isVeryCompact) ...[
                    OverlayToggle(
                      icon: SkotiqIcons.tag,
                      tooltip: 'Constellation labels',
                      isActive: renderConfig.showConstellationLabels,
                      onTap: ref
                          .read(skyRenderConfigProvider.notifier)
                          .toggleConstellationLabels,
                    ),
                    SizedBox(width: toggleSpacing),
                  ],
                  OverlayToggle(
                    icon: SkotiqIcons.circle,
                    tooltip: 'Horizon',
                    isActive: renderConfig.showHorizon,
                    onTap: ref
                        .read(skyRenderConfigProvider.notifier)
                        .toggleHorizon,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// Sidereal time needs a site. an em dash rather than a number for a longitude
  /// nobody gave: LST is exactly what an observer reads to decide what is
  /// transiting.
  String _formatHours(double? hours) {
    if (hours == null) return kReadoutUnknown;
    final h = hours.floor();
    final m = ((hours - h) * 60).floor();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

class OverlayChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;
  final bool compact;

  const OverlayChip({
    super.key,
    required this.icon,
    required this.label,
    required this.colors,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceOverlay.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 11 : 12, color: colors.textSecondary),
          SizedBox(width: compact ? 4 : 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact
                  ? SkotiqTypography.fontSize10
                  : SkotiqTypography.fontSize11,
              color: colors.textSecondary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class OverlayToggle extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;

  const OverlayToggle({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<OverlayToggle> createState() => _OverlayToggleState();
}

class _OverlayToggleState extends State<OverlayToggle> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final touchSize = AdaptiveSizing.of(context).minTouchTarget;
    final iconSize = touchSize <= 36 ? 14.0 : 16.0;

    return SkotiqTooltip(
      message: widget.tooltip,
      position: SkotiqTooltipPosition.bottom,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: touchSize,
            height: touchSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.isActive
                  ? colors.primary.withValues(alpha: 0.2)
                  : _isHovered
                      ? colors.surfaceOverlay.withValues(alpha: 0.5)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              border: widget.isActive
                  ? Border.all(color: colors.primary.withValues(alpha: 0.4))
                  : null,
            ),
            child: Icon(
              widget.icon,
              size: iconSize,
              color: widget.isActive ? colors.primary : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class TimeControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final SkotiqColors colors;
  final bool compact;

  const TimeControlButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.colors,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(compact ? 4 : 6),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        child: Icon(icon, size: compact ? 12 : 14, color: colors.primary),
      ),
    );
  }
}
