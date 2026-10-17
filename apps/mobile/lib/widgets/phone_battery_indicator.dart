// Phone battery indicator badge.
//
// Sits in the dashboard AppBar action row alongside NetworkStatusIndicator
// so the operator can glance at their phone's battery without leaving the
// app. When [PhoneBatteryState.isLowPower] is true, the badge flips to a
// red tint so the operator can see at a glance that the phone is running
// low on battery.
//
// The widget intentionally renders nothing on cold start (before the first
// sample lands) to avoid a flash of "-1%" or a placeholder shimmer; the
// AppBar layout reflows correctly once the badge appears. We use a
// Lucide-icons battery glyph rather than the Material icons set so it
// matches the visual weight of the network indicator next to it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../services/battery_service.dart';

/// Compact battery percentage + charging-state badge.
///
/// Renders:
///   * "75%" with a battery glyph at normal levels.
///   * "75%" tinted red when [isLowPower] fires.
///   * Same percentage with a small zap glyph overlaid when charging.
///   * Nothing when the OS has not yet delivered a sample (level < 0).
class PhoneBatteryIndicator extends ConsumerWidget {
  /// When true, render only the icon + percent in a 28 dp square. When
  /// false, include a longer label suitable for a settings row.
  final bool compact;

  const PhoneBatteryIndicator({super.key, this.compact = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batteryAsync = ref.watch(batteryStateProvider);
    final state = batteryAsync.valueOrNull;
    if (state == null || state.level < 0) {
      // No sample yet — render an empty zero-width box so the AppBar
      // layout doesn't pop in. Once the first sample arrives the badge
      // shows up alongside the network indicator without a layout jump.
      return const SizedBox.shrink();
    }

    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final isLowPower = state.isLowPower;
    final tint = isLowPower
        ? (colors.error)
        : (state.isCharging ? colors.success : colors.textSecondary);

    final tooltip = StringBuffer('Battery: ${state.level}%');
    if (state.isCharging) tooltip.write(' (charging)');

    final icon = state.isCharging
        ? LucideIcons.batteryCharging
        : _iconForLevel(state.level);

    return Tooltip(
      message: tooltip.toString(),
      child: Container(
        constraints: const BoxConstraints(minHeight: 28, minWidth: 28),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10,
          vertical: 4,
        ),
        decoration: isLowPower
            ? BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: tint),
            const SizedBox(width: 4),
            Text(
              '${state.level}%',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: tint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForLevel(int pct) {
    // Lucide ships four discrete battery glyphs (empty, low, medium, full)
    // plus the charging variant. Mapping ranges to glyphs gives the
    // operator a quick visual cue without leaning solely on the text.
    if (pct < 20) return LucideIcons.batteryWarning;
    if (pct < 50) return LucideIcons.batteryLow;
    if (pct < 80) return LucideIcons.batteryMedium;
    return LucideIcons.batteryFull;
  }
}
