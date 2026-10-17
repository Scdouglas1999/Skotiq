import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'observatory_format.dart';

/// Dedicated observatory / dome telemetry card for the cockpit.
///
/// Surfaces the live state of the three "building" devices that the generic
/// equipment telemetry strip treats as just-more-rows: the dome (shutter,
/// azimuth, slaved), the cover / flat-panel (cover state + flat light), and
/// the power switch box (per-channel on/off). Each block is gated on that
/// device's own connection state exactly like the six core devices, so an
/// operator watching an unattended observatory night can confirm "shutter
/// open, dome slaved, dew heaters on" without opening the Equipment screen.
///
/// Reads [domeStateProvider], [coverCalibratorStateProvider], and
/// [switchStateProvider] — the same providers the Equipment screen uses.
class RunDashboardObservatoryPanel extends ConsumerWidget {
  const RunDashboardObservatoryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final dome = ref.watch(domeStateProvider);
    final cover = ref.watch(coverCalibratorStateProvider);
    final sw = ref.watch(switchStateProvider);

    final domeConnected =
        dome.connectionState == DeviceConnectionState.connected;
    final coverConnected =
        cover.connectionState == DeviceConnectionState.connected &&
            (cover.hasCover || cover.hasCalibrator);
    final switchConnected =
        sw.connectionState == DeviceConnectionState.connected &&
            sw.channelCount > 0;

    final blocks = <Widget>[
      if (domeConnected) _DomeBlock(colors: colors, dome: dome),
      if (coverConnected) _CoverBlock(colors: colors, cover: cover),
      if (switchConnected) _SwitchBlock(colors: colors, sw: sw),
    ];

    // Hide the whole card when no observatory device is connected — most rigs
    // have no dome/cover/switch, so rendering a header + "No dome..." line
    // just wastes a slot. Mirrors the hide-when-empty pattern used by the
    // equipment telemetry strip and the quality/forensics panels.
    if (blocks.isEmpty) return const SizedBox.shrink();

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.warehouse, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'OBSERVATORY',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          for (var i = 0; i < blocks.length; i++) ...[
            blocks[i],
            if (i < blocks.length - 1)
              const SizedBox(height: SkotiqTokens.spaceMd),
          ],
        ],
      ),
    );
  }
}

class _DomeBlock extends StatelessWidget {
  final SkotiqColors colors;
  final DomeState dome;

  const _DomeBlock({required this.colors, required this.dome});

  @override
  Widget build(BuildContext context) {
    return _ObservatoryBlock(
      colors: colors,
      icon: LucideIcons.warehouse,
      name: 'Dome',
      deviceName: dome.deviceName,
      statusText: observatoryDomeStatusText(dome),
      statusColor: observatoryDomeShutterColor(dome, colors),
      rows: [
        _Row(
          colors: colors,
          label: 'Shutter',
          value: observatoryDomeShutterLabel(dome),
          valueColor: observatoryDomeShutterColor(dome, colors),
        ),
        if (dome.azimuth != null)
          _Row(
            colors: colors,
            label: 'Azimuth',
            value: '${dome.azimuth!.toStringAsFixed(1)}°',
          ),
        _Row(
          colors: colors,
          label: 'Slaved',
          value: dome.isSlaved ? 'Yes' : 'No',
          valueColor: dome.isSlaved ? colors.success : colors.textSecondary,
        ),
        if (dome.isParked)
          _Row(
            colors: colors,
            label: 'Parked',
            value: 'Yes',
            valueColor: colors.textMuted,
          ),
      ],
    );
  }
}

class _CoverBlock extends StatelessWidget {
  final SkotiqColors colors;
  final CoverCalibratorState cover;

  const _CoverBlock({required this.colors, required this.cover});

  @override
  Widget build(BuildContext context) {
    return _ObservatoryBlock(
      colors: colors,
      icon: LucideIcons.panelTopClose,
      name: 'Cover / flat panel',
      deviceName: cover.deviceName,
      statusText: cover.hasCover
          ? observatoryCoverStatusLabel(cover.coverStatus)
          : observatoryCalibratorStatusLabel(cover.calibratorStatus),
      statusColor: cover.hasCover
          ? observatoryCoverStatusColor(cover.coverStatus, colors)
          : observatoryCalibratorStatusColor(cover.calibratorStatus, colors),
      rows: [
        if (cover.hasCover)
          _Row(
            colors: colors,
            label: 'Cover',
            value: observatoryCoverStatusLabel(cover.coverStatus),
            valueColor: observatoryCoverStatusColor(cover.coverStatus, colors),
          ),
        if (cover.hasCalibrator)
          _Row(
            colors: colors,
            label: 'Flat light',
            value: observatoryCalibratorStatusLabel(cover.calibratorStatus),
            valueColor: observatoryCalibratorStatusColor(
                cover.calibratorStatus, colors),
          ),
        if (cover.hasCalibrator && cover.isCalibratorOn)
          _Row(
            colors: colors,
            label: 'Brightness',
            value: '${cover.brightness}/${cover.maxBrightness}',
          ),
      ],
    );
  }
}

class _SwitchBlock extends StatelessWidget {
  final SkotiqColors colors;
  final SwitchState sw;

  const _SwitchBlock({required this.colors, required this.sw});

  @override
  Widget build(BuildContext context) {
    final channels = observatorySwitchChannels(sw);
    final shown = channels.where((c) => !c.isOverflow).length;
    return _ObservatoryBlock(
      colors: colors,
      icon: LucideIcons.toggleLeft,
      name: 'Switches',
      deviceName: sw.deviceName,
      statusText: observatorySwitchSummaryLabel(sw),
      statusColor: colors.textSecondary,
      rows: [
        for (final ch in channels)
          _Row(
            colors: colors,
            label: ch.isOverflow ? '…' : ch.label,
            value: ch.isOverflow
                ? '+${sw.channelStates.length - shown} more'
                : (ch.on ? 'On' : 'Off'),
            valueColor: ch.isOverflow
                ? colors.textMuted
                : (ch.on ? colors.success : colors.textMuted),
          ),
      ],
    );
  }
}

class _ObservatoryBlock extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String name;
  final String? deviceName;
  final String statusText;
  final Color statusColor;
  final List<_Row> rows;

  const _ObservatoryBlock({
    required this.colors,
    required this.icon,
    required this.name,
    required this.deviceName,
    required this.statusText,
    required this.statusColor,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: colors.textSecondary),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                name,
                style:
                    SkotiqTypography.h6.copyWith(color: colors.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: SkotiqDecorations.statusChip(
                statusColor,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                bordered: false,
              ),
              child: Text(
                statusText,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
        if (deviceName != null && deviceName!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            deviceName!,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (rows.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          ...rows,
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final Color? valueColor;

  const _Row({
    required this.colors,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            value,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              fontWeight: FontWeight.w600,
              color: valueColor ?? colors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
