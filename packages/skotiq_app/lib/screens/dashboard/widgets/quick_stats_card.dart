import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import 'glass_card.dart';

class QuickStatsCard extends ConsumerWidget {
  final SkotiqColors colors;

  const QuickStatsCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // Use select() to only rebuild when specific fields change
    final cameraConnected =
        ref.watch(cameraStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final cameraTemp =
        ref.watch(cameraStateProvider.select((s) => s.temperature));

    final guiderConnected =
        ref.watch(guiderStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final guiderIsGuiding =
        ref.watch(guiderStateProvider.select((s) => s.isGuiding));
    final guiderRms = ref.watch(guiderStateProvider.select((s) => s.rmsTotal));

    final hfr = ref.watch(lastImageStatsProvider.select((s) => s?.hfr));

    final focuserConnected =
        ref.watch(focuserStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;
    final focuserPosition =
        ref.watch(focuserStateProvider.select((s) => s.position));

    // Format temperature (same logic as Imaging tab)
    String tempValue = kReadoutUnknown;
    if (cameraConnected) {
      if (cameraTemp != null) {
        tempValue = '${cameraTemp.toStringAsFixed(1)}°C';
      } else {
        tempValue = kReadoutUnknown;
      }
    }

    // Format RMS (same logic as Imaging tab)
    String rmsValue = kReadoutUnknown;
    if (guiderConnected && guiderIsGuiding && guiderRms != null) {
      rmsValue = '${guiderRms.toStringAsFixed(2)}"';
    }

    // Format HFR (same logic as Imaging tab)
    String hfrValue = kReadoutUnknown;
    if (hfr != null) {
      hfrValue = hfr.toStringAsFixed(2);
    }

    // Format Focus position
    String focusValue = kReadoutUnknown;
    if (focuserConnected) {
      if (focuserPosition != null) {
        focusValue = focuserPosition.toString();
      } else {
        focusValue = kReadoutUnknown;
      }
    }

    // Sensor temp / focus / HFR / RMS are exactly the "read it from across the
    // room" readouts the Glance mode toggle promises, so they answer it.
    final glance = ref.watch(glanceModeProvider);

    return DashboardGlassCard(
      colors: colors,
      padding: const EdgeInsets.all(0),
      child: Row(
        children: [
          _QuickStatItem(
            icon: LucideIcons.thermometer,
            label: l10n.text('sensor'),
            value: tempValue,
            colors: colors,
            glance: glance,
            isFirst: true,
          ),
          _QuickStatItem(
            icon: LucideIcons.focus,
            label: l10n.text('focus'),
            value: focusValue,
            colors: colors,
            glance: glance,
          ),
          _QuickStatItem(
            icon: LucideIcons.target,
            label: l10n.text('hfr'),
            value: hfrValue,
            colors: colors,
            glance: glance,
          ),
          _QuickStatItem(
            icon: LucideIcons.activity,
            label: l10n.text('rms'),
            value: rmsValue,
            colors: colors,
            glance: glance,
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _QuickStatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool glance;
  final bool isFirst;
  final bool isLast;

  const _QuickStatItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.colors,
    required this.glance,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(
                  right: BorderSide(
                    color: colors.border.withValues(alpha: 0.5),
                  ),
                ),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: colors.primary),
            const SizedBox(height: 8),
            Text(
              value,
              style: SkotiqTypography.h4.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: SkotiqTypography.glanceStyle(
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
                enabled: glance,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
