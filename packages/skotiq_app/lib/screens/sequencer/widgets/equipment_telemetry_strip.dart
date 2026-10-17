import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard/observatory_format.dart';
import 'run_dashboard/run_dashboard_format.dart';

/// Compact telemetry strip showing live device state: camera temperature,
/// focuser position, guiding RMS, current filter, and mount tracking
/// status.
///
/// Renders in two layouts driven by [direction]:
///
///   * [Axis.horizontal] (default): the 32 px-tall strip below the
///     sequencer toolbar. Each telemetry item is an icon + label + value
///     pair laid out left to right with separators.
///   * [Axis.vertical]: a card with per-device blocks stacked top-down,
///     used by the Run Dashboard's left column. It renders more per-device
///     detail (RA/Dec, side-of-pier, cooler power, …) because the dashboard
///     has vertical real-estate the toolbar strip does not.
///
/// Both layouts read the same Riverpod providers, so they always agree.
class EquipmentTelemetryStrip extends ConsumerWidget {
  final SkotiqColors colors;
  final Axis direction;

  const EquipmentTelemetryStrip({
    super.key,
    required this.colors,
    this.direction = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraState = ref.watch(cameraStateProvider);
    final mountState = ref.watch(mountStateProvider);
    final focuserState = ref.watch(focuserStateProvider);
    final filterWheelState = ref.watch(filterWheelStateProvider);
    final guiderState = ref.watch(guiderStateProvider);
    final rotatorState = ref.watch(rotatorStateProvider);
    // Observatory devices — surfaced exactly like the six core devices,
    // each gated on its own connection state so an unattended-night
    // operator can confirm the dome shutter, flat cover, and power switches
    // at a glance instead of having to open the Equipment screen.
    final domeState = ref.watch(domeStateProvider);
    final coverState = ref.watch(coverCalibratorStateProvider);
    final switchState = ref.watch(switchStateProvider);
    final afResult = ref.watch(autofocusResultProvider);
    final exposureProgress = ref.watch(exposureProgressProvider);

    final hasAnyDevice = cameraState.connectionState ==
            DeviceConnectionState.connected ||
        mountState.connectionState == DeviceConnectionState.connected ||
        focuserState.connectionState == DeviceConnectionState.connected ||
        filterWheelState.connectionState == DeviceConnectionState.connected ||
        rotatorState.connectionState == DeviceConnectionState.connected ||
        guiderState.connectionState == DeviceConnectionState.connected ||
        domeState.connectionState == DeviceConnectionState.connected ||
        coverState.connectionState == DeviceConnectionState.connected ||
        switchState.connectionState == DeviceConnectionState.connected;

    if (direction == Axis.vertical) {
      return _VerticalLayout(
        colors: colors,
        camera: cameraState,
        mount: mountState,
        focuser: focuserState,
        filterWheel: filterWheelState,
        guider: guiderState,
        rotator: rotatorState,
        dome: domeState,
        cover: coverState,
        switchDevice: switchState,
        afResult: afResult,
        exposureProgress: exposureProgress,
        hasAnyDevice: hasAnyDevice,
      );
    }

    // Original horizontal strip — preserved verbatim so existing
    // callers continue to render identical pixels.
    if (!hasAnyDevice) return const SizedBox.shrink();
    return _HorizontalStrip(
      colors: colors,
      camera: cameraState,
      mount: mountState,
      focuser: focuserState,
      filterWheel: filterWheelState,
      guider: guiderState,
      dome: domeState,
      cover: coverState,
      switchDevice: switchState,
    );
  }
}

class _HorizontalStrip extends StatelessWidget {
  final SkotiqColors colors;
  final CameraStateSnapshot camera;
  final MountState mount;
  final FocuserState focuser;
  final FilterWheelState filterWheel;
  final GuiderState guider;
  final DomeState dome;
  final CoverCalibratorState cover;
  final SwitchState switchDevice;

  const _HorizontalStrip({
    required this.colors,
    required this.camera,
    required this.mount,
    required this.focuser,
    required this.filterWheel,
    required this.guider,
    required this.dome,
    required this.cover,
    required this.switchDevice,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.activity, size: 12, color: colors.textMuted),
          const SizedBox(width: 8),
          Text(
            'TELEMETRY',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize9,
              fontWeight: FontWeight.w700,
              color: colors.textMuted,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 16),
          _TelemetrySeparator(colors: colors),
          const SizedBox(width: 12),
          // Telemetry items scroll horizontally so the strip never overflows
          // when many devices are connected on a narrow window.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (camera.connectionState == DeviceConnectionState.connected)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.thermometer,
                      label: 'Cam',
                      value: camera.temperature != null
                          ? '${camera.temperature!.toStringAsFixed(1)}°C'
                          : '--',
                      valueColor: _tempColor(camera.temperature, colors),
                    ),
                  if (focuser.connectionState ==
                      DeviceConnectionState.connected)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.focus,
                      label: 'Focus',
                      value: focuser.position?.toString() ?? '--',
                      valueColor: focuser.isMoving ? colors.warning : null,
                    ),
                  if (filterWheel.connectionState ==
                      DeviceConnectionState.connected)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.filter,
                      label: 'Filter',
                      value: filterWheel.currentFilterName ??
                          'Pos ${filterWheel.currentPosition ?? '?'}',
                      valueColor: filterWheel.isMoving ? colors.warning : null,
                    ),
                  if (guider.connectionState == DeviceConnectionState.connected)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.crosshair,
                      label: 'RMS',
                      value: guider.isGuiding
                          ? (guider.rmsTotal != null
                              ? '${guider.rmsTotal!.toStringAsFixed(2)}"'
                              : 'Guiding')
                          : 'Idle',
                      valueColor: _guidingRmsColor(guider, colors),
                    ),
                  if (mount.connectionState == DeviceConnectionState.connected)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.locateFixed,
                      label: 'Mount',
                      value: mount.isSlewing
                          ? 'Slewing'
                          : mount.isTracking
                              ? 'Tracking'
                              : mount.isParked
                                  ? 'Parked'
                                  : 'Idle',
                      valueColor: mount.isSlewing
                          ? colors.warning
                          : mount.isTracking
                              ? colors.success
                              : mount.isParked
                                  ? colors.textMuted
                                  : colors.error,
                    ),
                  if (dome.connectionState == DeviceConnectionState.connected)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.warehouse,
                      label: 'Dome',
                      value: observatoryDomeShutterLabel(dome),
                      valueColor: observatoryDomeShutterColor(dome, colors),
                    ),
                  if (cover.connectionState ==
                          DeviceConnectionState.connected &&
                      cover.hasCover)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.panelTopClose,
                      label: 'Cover',
                      value: observatoryCoverStatusLabel(cover.coverStatus),
                      valueColor: observatoryCoverStatusColor(
                          cover.coverStatus, colors),
                    ),
                  if (switchDevice.connectionState ==
                          DeviceConnectionState.connected &&
                      switchDevice.channelCount > 0)
                    _TelemetryItem(
                      colors: colors,
                      icon: LucideIcons.toggleLeft,
                      label: 'Switch',
                      value: observatorySwitchSummaryLabel(switchDevice),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerticalLayout extends StatelessWidget {
  final SkotiqColors colors;
  final CameraStateSnapshot camera;
  final MountState mount;
  final FocuserState focuser;
  final FilterWheelState filterWheel;
  final GuiderState guider;
  final RotatorState rotator;
  final DomeState dome;
  final CoverCalibratorState cover;
  final SwitchState switchDevice;
  final AutofocusResult? afResult;
  final ExposureProgress exposureProgress;
  final bool hasAnyDevice;

  const _VerticalLayout({
    required this.colors,
    required this.camera,
    required this.mount,
    required this.focuser,
    required this.filterWheel,
    required this.guider,
    required this.rotator,
    required this.dome,
    required this.cover,
    required this.switchDevice,
    required this.afResult,
    required this.exposureProgress,
    required this.hasAnyDevice,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[
      if (camera.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.camera,
          name: 'Camera',
          deviceName: camera.deviceName,
          // The device-state flag only tracks manual captures; a
          // sequencer-driven exposure reports through exposureProgress —
          // without the OR the camera read "Idle" mid-60s-exposure
          // (waveM-close M-3).
          statusText: camera.isExposing || exposureProgress.remaining > 0
              ? 'Exposing'
              : 'Idle',
          statusColor: camera.isExposing || exposureProgress.remaining > 0
              ? colors.success
              : colors.textSecondary,
          rows: [
            if (camera.temperature != null)
              _TelemetryRow(
                colors: colors,
                label: 'Sensor',
                value: '${camera.temperature!.toStringAsFixed(1)}°C',
                valueColor: _tempColor(camera.temperature, colors),
              ),
            if (camera.coolerPower != null)
              _TelemetryRow(
                colors: colors,
                label: 'Cooler',
                value: '${camera.coolerPower!.toStringAsFixed(0)}%',
              ),
            if (exposureProgress.remaining > 0)
              _TelemetryRow(
                colors: colors,
                label: 'Remaining',
                value: formatSeconds(exposureProgress.remaining),
                valueColor: colors.primary,
              ),
          ],
        ),
      if (mount.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.compass,
          name: 'Mount',
          deviceName: mount.deviceName,
          statusText: mount.isSlewing
              ? 'Slewing'
              : mount.isTracking
                  ? 'Tracking'
                  : mount.isParked
                      ? 'Parked'
                      : 'Idle',
          statusColor: mount.isSlewing
              ? colors.warning
              : mount.isTracking
                  ? colors.success
                  : mount.isParked
                      ? colors.textMuted
                      : colors.error,
          rows: [
            if (mount.ra != null && mount.dec != null) ...[
              _TelemetryRow(
                colors: colors,
                label: 'RA',
                value: formatRA(mount.ra!),
              ),
              _TelemetryRow(
                colors: colors,
                label: 'Dec',
                value: formatDec(mount.dec!),
              ),
            ],
            if (mount.altitude != null)
              _TelemetryRow(
                colors: colors,
                label: 'Alt',
                value: '${mount.altitude!.toStringAsFixed(1)}°',
              ),
            if (mount.sideOfPier != null && mount.sideOfPier!.isNotEmpty)
              _TelemetryRow(
                colors: colors,
                label: 'Pier',
                value: mount.sideOfPier!,
              ),
          ],
        ),
      if (focuser.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.focus,
          name: 'Focuser',
          deviceName: focuser.deviceName,
          statusText: focuser.isMoving ? 'Moving' : 'Idle',
          statusColor: focuser.isMoving ? colors.warning : colors.textSecondary,
          rows: [
            if (focuser.position != null)
              _TelemetryRow(
                colors: colors,
                label: 'Position',
                value: focuser.position.toString(),
              ),
            if (focuser.temperature != null)
              _TelemetryRow(
                colors: colors,
                label: 'Temp',
                value: '${focuser.temperature!.toStringAsFixed(1)}°C',
              ),
            if (afResult != null)
              _TelemetryRow(
                colors: colors,
                label: 'Last AF HFR',
                value: afResult!.bestHfr.toStringAsFixed(2),
                valueColor: colors.primary,
              ),
          ],
        ),
      if (filterWheel.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.filter,
          name: 'Filter wheel',
          deviceName: filterWheel.deviceName,
          statusText: filterWheel.isMoving ? 'Changing' : 'Ready',
          statusColor:
              filterWheel.isMoving ? colors.warning : colors.textSecondary,
          rows: [
            _TelemetryRow(
              colors: colors,
              label: 'Filter',
              value: filterWheel.currentFilterName ??
                  'Pos ${filterWheel.currentPosition ?? '?'}',
              valueColor: colors.primary,
            ),
          ],
        ),
      if (rotator.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.rotateCw,
          name: 'Rotator',
          deviceName: rotator.deviceName,
          statusText: rotator.isMoving ? 'Rotating' : 'Idle',
          statusColor: rotator.isMoving ? colors.warning : colors.textSecondary,
          rows: [
            if (rotator.position != null)
              _TelemetryRow(
                colors: colors,
                label: 'Angle',
                value: '${rotator.position!.toStringAsFixed(2)}°',
              ),
          ],
        ),
      if (guider.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.crosshair,
          name: 'Guider',
          deviceName: guider.deviceName,
          statusText: guider.isCalibrating
              ? 'Calibrating'
              : guider.isGuiding
                  ? 'Guiding'
                  : 'Idle',
          statusColor: guider.isCalibrating
              ? colors.warning
              : guider.isGuiding
                  ? colors.success
                  : colors.textMuted,
          rows: [
            // Only while guiding: these values persist in guider state after a
            // session stops, so an unguarded check shows the previous run's RMS
            // directly beneath this block's own "Idle" status label.
            if (guider.isGuiding && guider.rmsTotal != null)
              _TelemetryRow(
                colors: colors,
                label: 'RMS Tot',
                value: '${guider.rmsTotal!.toStringAsFixed(2)}"',
                valueColor: _guidingRmsColor(guider, colors),
              ),
            if (guider.isGuiding && guider.rmsRa != null)
              _TelemetryRow(
                colors: colors,
                label: 'RMS RA',
                value: '${guider.rmsRa!.toStringAsFixed(2)}"',
              ),
            if (guider.isGuiding && guider.rmsDec != null)
              _TelemetryRow(
                colors: colors,
                label: 'RMS Dec',
                value: '${guider.rmsDec!.toStringAsFixed(2)}"',
              ),
          ],
        ),
      if (dome.connectionState == DeviceConnectionState.connected)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.warehouse,
          name: 'Dome',
          deviceName: dome.deviceName,
          statusText: observatoryDomeStatusText(dome),
          statusColor: observatoryDomeShutterColor(dome, colors),
          rows: [
            _TelemetryRow(
              colors: colors,
              label: 'Shutter',
              value: observatoryDomeShutterLabel(dome),
              valueColor: observatoryDomeShutterColor(dome, colors),
            ),
            if (dome.azimuth != null)
              _TelemetryRow(
                colors: colors,
                label: 'Azimuth',
                value: '${dome.azimuth!.toStringAsFixed(1)}°',
              ),
            _TelemetryRow(
              colors: colors,
              label: 'Slaved',
              value: dome.isSlaved ? 'Yes' : 'No',
              valueColor: dome.isSlaved ? colors.success : colors.textSecondary,
            ),
          ],
        ),
      if (cover.connectionState == DeviceConnectionState.connected &&
          (cover.hasCover || cover.hasCalibrator))
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.panelTopClose,
          name: 'Cover / flat panel',
          deviceName: cover.deviceName,
          statusText: cover.hasCover
              ? observatoryCoverStatusLabel(cover.coverStatus)
              : observatoryCalibratorStatusLabel(cover.calibratorStatus),
          statusColor: cover.hasCover
              ? observatoryCoverStatusColor(cover.coverStatus, colors)
              : observatoryCalibratorStatusColor(
                  cover.calibratorStatus, colors),
          rows: [
            if (cover.hasCover)
              _TelemetryRow(
                colors: colors,
                label: 'Cover',
                value: observatoryCoverStatusLabel(cover.coverStatus),
                valueColor:
                    observatoryCoverStatusColor(cover.coverStatus, colors),
              ),
            if (cover.hasCalibrator)
              _TelemetryRow(
                colors: colors,
                label: 'Flat light',
                value: observatoryCalibratorStatusLabel(cover.calibratorStatus),
                valueColor: observatoryCalibratorStatusColor(
                    cover.calibratorStatus, colors),
              ),
            if (cover.hasCalibrator && cover.isCalibratorOn)
              _TelemetryRow(
                colors: colors,
                label: 'Brightness',
                value: '${cover.brightness}/${cover.maxBrightness}',
              ),
          ],
        ),
      if (switchDevice.connectionState == DeviceConnectionState.connected &&
          switchDevice.channelCount > 0)
        _DeviceBlock(
          colors: colors,
          icon: LucideIcons.toggleLeft,
          name: 'Switches',
          deviceName: switchDevice.deviceName,
          statusText: observatorySwitchSummaryLabel(switchDevice),
          statusColor: colors.textSecondary,
          rows: _switchTelemetryRows(switchDevice, colors),
        ),
    ];

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.activity, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Equipment',
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
          if (blocks.isEmpty)
            Text(
              'No equipment connected',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textMuted),
            )
          else
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

Color? _tempColor(double? temp, SkotiqColors colors) {
  if (temp == null) return null;
  if (temp < -5) return colors.info;
  if (temp > 25) return colors.warning;
  return null;
}

Color? _guidingRmsColor(GuiderState state, SkotiqColors colors) {
  if (!state.isGuiding) return colors.textMuted;
  if (state.isCalibrating) return colors.warning;
  final rms = state.rmsTotal;
  if (rms == null) return null;
  if (rms < 1.0) return colors.success;
  if (rms < 2.0) return colors.warning;
  return colors.error;
}

// Observatory device formatting (dome / cover / switch) lives in
// `run_dashboard/observatory_format.dart` so the strip and the dedicated
// Observatory cockpit panel share one source of truth. This local helper just
// adapts the shared switch-channel data into the strip's `_TelemetryRow`.
List<_TelemetryRow> _switchTelemetryRows(SwitchState sw, SkotiqColors colors) {
  final channels = observatorySwitchChannels(sw);
  final shown = channels.where((c) => !c.isOverflow).length;
  return [
    for (final ch in channels)
      _TelemetryRow(
        colors: colors,
        label: ch.isOverflow ? '…' : ch.label,
        value: ch.isOverflow
            ? '+${sw.channelStates.length - shown} more'
            : (ch.on ? 'On' : 'Off'),
        valueColor: ch.isOverflow
            ? colors.textSecondary
            : (ch.on ? colors.success : colors.textMuted),
      ),
  ];
}

class _TelemetryItem extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _TelemetryItem({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: colors.textMuted),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: valueColor ?? colors.textSecondary,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TelemetrySeparator extends StatelessWidget {
  final SkotiqColors colors;

  const _TelemetrySeparator({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      color: colors.border,
    );
  }
}

class _DeviceBlock extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String name;
  final String? deviceName;
  final String statusText;
  final Color statusColor;
  final List<_TelemetryRow> rows;

  const _DeviceBlock({
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
                style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
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
              color: colors.textMuted,
            ),
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

class _TelemetryRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final Color? valueColor;

  const _TelemetryRow({
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
          Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
          ),
          const Spacer(),
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
