import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../services/battery_service.dart';

/// The phone's battery in the top bar, shown only when it changes what the
/// app does: while the battery is low or battery saver is on, the app checks
/// the rig less often. A tap says so. Nothing is drawn the rest of the time.
class PhoneBatteryIndicator extends ConsumerWidget {
  const PhoneBatteryIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batteryStateProvider).valueOrNull;
    if (state == null ||
        state.level < 0 ||
        !(state.isLowPower || state.isSaverOn)) {
      return const SizedBox.shrink();
    }

    final colors = SkotiqColors.of(context);
    final tone = state.isLowPower ? colors.error : colors.warning;
    final explanation = _explanation(state);
    return Padding(
      padding: const EdgeInsets.only(right: SkotiqTokens.spaceXs),
      child: Semantics(
        container: true,
        button: true,
        enabled: true,
        label: explanation,
        excludeSemantics: true,
        child: InkWell(
          onTap: () => context.showWarningSnackBar(explanation),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: ShellChromeMetrics.titleBarHeight,
            ),
            child: Center(
              widthFactor: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceSm,
                  vertical: SkotiqTokens.spaceXs,
                ),
                decoration: SkotiqDecorations.chip(
                  colors,
                  tone: tone,
                  radius: SkotiqTokens.radiusSm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      state.isCharging
                          ? LucideIcons.batteryCharging
                          : _iconForLevel(state.level),
                      size: SkotiqTokens.iconXs,
                      color: tone,
                    ),
                    const SizedBox(width: SkotiqTokens.spaceXs),
                    Text(
                      '${state.level}%',
                      style: SkotiqTypography.labelStrongSm.copyWith(
                        color: tone,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _explanation(PhoneBatteryState state) {
    final why = state.isLowPower
        ? 'Phone battery at ${state.level}%.'
        : 'Battery saver is on.';
    final until = state.isLowPower
        ? 'until the phone is charging'
        : 'while battery saver is on';
    return '$why Skotiq checks the rig a third as often $until. Alerts '
        'still arrive at once.';
  }

  static IconData _iconForLevel(int pct) {
    if (pct < 20) return LucideIcons.batteryWarning;
    if (pct < 50) return LucideIcons.batteryLow;
    if (pct < 80) return LucideIcons.batteryMedium;
    return LucideIcons.batteryFull;
  }
}
