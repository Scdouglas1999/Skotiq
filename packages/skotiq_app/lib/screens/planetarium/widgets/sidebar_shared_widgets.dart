import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:intl/intl.dart';

/// Shared DSO type name formatter used by Tonight and Catalog tabs.
String dsoTypeName(DsoType type) {
  switch (type) {
    case DsoType.galaxy:
      return 'Galaxy';
    case DsoType.nebula:
      return 'Nebula';
    case DsoType.openCluster:
      return 'Open Cluster';
    case DsoType.globularCluster:
      return 'Globular Cluster';
    case DsoType.planetaryNebula:
      return 'Planetary Nebula';
    case DsoType.supernova:
      return 'Supernova Remnant';
    default:
      return 'DSO';
  }
}

class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final Color? valueColor;

  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              fontWeight: FontWeight.w500,
              color: valueColor ?? colors.textPrimary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final Widget child;
  final SkotiqColors colors;

  const InfoCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.child,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Icon(icon, size: 14, color: color),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: SkotiqTypography.labelStrong
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class TwilightRow extends StatelessWidget {
  final String label;
  final String time;
  final bool isPrimary;
  final SkotiqColors colors;

  const TwilightRow({
    super.key,
    required this.label,
    required this.time,
    this.isPrimary = false,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: isPrimary ? colors.textPrimary : colors.textSecondary,
              fontWeight: isPrimary ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
          Text(
            time,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              fontWeight: isPrimary ? FontWeight.w600 : FontWeight.w500,
              color: isPrimary ? colors.primary : colors.textPrimary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Darkness duration card showing total imaging time
class DarknessCard extends StatelessWidget {
  final TwilightTimes twilight;
  final SkotiqColors colors;

  const DarknessCard({
    super.key,
    required this.twilight,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final duration = twilight.darknessDuration;
    if (duration == null) return const SizedBox.shrink();

    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;

    return SkotiqCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.15),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Icon(SkotiqIcons.moon, size: 16, color: colors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Darkness',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${hours}h ${minutes.toString().padLeft(2, '0')}m',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize20,
                        fontWeight: FontWeight.bold,
                        color: colors.primary,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 4,
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline2),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: hours,
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline2),
                    ),
                  ),
                ),
                if (hours < 12)
                  Expanded(
                    flex: 12 - hours,
                    child: const SizedBox(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Astro Dusk: ${DateFormat('HH:mm').format(twilight.astronomicalDusk!.toLocal())}',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: colors.textMuted),
              ),
              Text(
                'Astro Dawn: ${DateFormat('HH:mm').format(twilight.astronomicalDawn!.toLocal())}',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: colors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class TargetCard extends StatefulWidget {
  final String name;
  final String catalog;
  final String type;

  /// Headline value for this card — hours of usable darkness on the Tonight
  /// tab, magnitude in the catalog list. Rendered in the success colour.
  final String? metric;
  final String? magnitude;

  /// One-line qualifier under the headline (peak altitude and time, 'mag', …).
  final String caption;
  final SkotiqColors colors;
  final VoidCallback? onTap;
  final VoidCallback? onSendToFraming;
  final VoidCallback? onAddToSequencer;

  const TargetCard({
    super.key,
    required this.name,
    required this.catalog,
    required this.type,
    this.metric,
    this.magnitude,
    required this.caption,
    required this.colors,
    this.onTap,
    this.onSendToFraming,
    this.onAddToSequencer,
  });

  @override
  State<TargetCard> createState() => _TargetCardState();
}

class _TargetCardState extends State<TargetCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.colors.surfaceAlt
                : widget.colors.background,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: _isHovered
                  ? widget.colors.primary.withValues(alpha: 0.5)
                  : widget.colors.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SkotiqTypography.labelStrong
                                .copyWith(color: widget.colors.textPrimary),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  widget.colors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(
                                  SkotiqTokens.radiusInline4),
                            ),
                            constraints: const BoxConstraints(maxWidth: 72),
                            child: Text(
                              widget.catalog,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize10,
                                fontWeight: FontWeight.w600,
                                color: widget.colors.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: widget.colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onSendToFraming != null ||
                  widget.onAddToSequencer != null) ...[
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onSendToFraming != null)
                      Tooltip(
                        message: 'Frame target',
                        child: IconButton(
                          icon: const Icon(SkotiqIcons.frame, size: 15),
                          color: widget.colors.primary,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          onPressed: widget.onSendToFraming,
                        ),
                      ),
                    if (widget.onAddToSequencer != null)
                      Tooltip(
                        message: 'Add to sequencer',
                        child: IconButton(
                          icon: const Icon(LucideIcons.listPlus, size: 15),
                          color: widget.colors.primary,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          onPressed: widget.onAddToSequencer,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(width: 8),
              // Bounded so a caption longer than a bare HH:MM cannot push the
              // row past a narrow sidebar and strike the overflow stripe.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      widget.magnitude ?? widget.metric ?? '-',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.labelStrong.copyWith(
                        // Magnitude is a neutral catalog value, not a measure
                        // of how good tonight is — keep it out of the
                        // success-green slot.
                        color: widget.magnitude != null
                            ? widget.colors.textSecondary
                            : widget.colors.success,
                      ),
                    ),
                    Text(
                      widget.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize10,
                        color: widget.colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
