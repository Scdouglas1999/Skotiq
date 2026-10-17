import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'glass_card.dart';

class EquipmentStatusCard extends ConsumerWidget {
  final SkotiqColors colors;

  const EquipmentStatusCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Use select() to only rebuild when connection state changes
    final cameraConnected =
        ref.watch(cameraStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final mountConnected =
        ref.watch(mountStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final guiderConnected =
        ref.watch(guiderStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final focuserConnected =
        ref.watch(focuserStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final filterWheelConnected =
        ref.watch(filterWheelStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;

    final connectedCount = [
      cameraConnected,
      mountConnected,
      guiderConnected,
      focuserConnected,
      filterWheelConnected
    ].where((c) => c).length;

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.plug,
            title: 'Equipment',
            accent: connectedCount > 0 ? colors.success : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$connectedCount/5',
                  style: SkotiqTypography.labelQuiet.copyWith(
                    color: connectedCount == 5
                        ? colors.success
                        : colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => context.go('/equipment'),
                  child: Text(
                    'Manage',
                    style: SkotiqTypography.labelQuiet.copyWith(
                      color: colors.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: DashboardCardStyle.headerGap),

          // Compact horizontal icon row
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              color: colors.surfaceAlt.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _CompactEquipmentIcon(
                  icon: LucideIcons.camera,
                  label: 'Cam',
                  isConnected: cameraConnected,
                  colors: colors,
                ),
                _CompactEquipmentIcon(
                  icon: LucideIcons.move3d,
                  label: 'Mnt',
                  isConnected: mountConnected,
                  colors: colors,
                ),
                _CompactEquipmentIcon(
                  icon: LucideIcons.crosshair,
                  label: 'Gdr',
                  isConnected: guiderConnected,
                  colors: colors,
                ),
                _CompactEquipmentIcon(
                  icon: LucideIcons.focus,
                  label: 'Foc',
                  isConnected: focuserConnected,
                  colors: colors,
                ),
                _CompactEquipmentIcon(
                  icon: LucideIcons.circle,
                  label: 'FW',
                  isConnected: filterWheelConnected,
                  colors: colors,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact equipment status icon for horizontal display
class _CompactEquipmentIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isConnected;
  final SkotiqColors colors;

  const _CompactEquipmentIcon({
    required this.icon,
    required this.label,
    required this.isConnected,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label: ${isConnected ? "Connected" : "Disconnected"}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: isConnected
                ? SkotiqDecorations.statusChip(
                    colors.success,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  )
                : BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                    border: Border.all(color: colors.border),
                  ),
            child: Icon(
              icon,
              size: 14,
              color: isConnected ? colors.success : colors.textMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(
                color: isConnected ? colors.textSecondary : colors.textMuted),
          ),
        ],
      ),
    );
  }
}
