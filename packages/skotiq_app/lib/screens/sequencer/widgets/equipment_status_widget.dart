import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/device_format_utils.dart';

/// Get display name for a device, preferring deviceName, falling back to formatted deviceId
String _getDeviceDisplayName(String? deviceName, String? deviceId) {
  if (deviceName != null && deviceName.isNotEmpty) {
    return deviceName;
  }
  if (deviceId != null && deviceId.isNotEmpty) {
    return formatDeviceId(deviceId);
  }
  return 'Unknown';
}

/// Shows equipment connection status in a compact format for the sequencer
class EquipmentStatusWidget extends ConsumerWidget {
  final SkotiqColors colors;
  final bool expanded;

  const EquipmentStatusWidget({
    required this.colors,
    this.expanded = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch connected devices
    final connectedDevices = ref.watch(connectedDevicesProvider);

    return connectedDevices.when(
      data: (devices) => _buildStatusBar(context, ref, devices),
      loading: () => _buildLoadingState(),
      error: (_, __) => _buildErrorState(),
    );
  }

  Widget _buildStatusBar(
      BuildContext context, WidgetRef ref, List<DeviceInfo> devices) {
    final hasCamera = devices.any((d) => d.deviceType == DeviceType.camera);
    final hasMount = devices.any((d) => d.deviceType == DeviceType.mount);
    final hasFocuser = devices.any((d) => d.deviceType == DeviceType.focuser);
    final hasFilterWheel =
        devices.any((d) => d.deviceType == DeviceType.filterWheel);
    final hasGuider = devices.any((d) => d.deviceType == DeviceType.guider);

    if (expanded) {
      return SkotiqCard(
        variant: CardVariant.subtle,
        padding: const EdgeInsets.all(12),
        borderRadius: SkotiqTokens.radiusInline8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.plug, size: 12, color: colors.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Equipment Status',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w600,
                    color: colors.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ExpandedStatusChip(
                  colors: colors,
                  icon: LucideIcons.camera,
                  label: 'Camera',
                  isConnected: hasCamera,
                  deviceName: _getDeviceName(devices, DeviceType.camera),
                ),
                _ExpandedStatusChip(
                  colors: colors,
                  icon: LucideIcons.locateFixed,
                  label: 'Mount',
                  isConnected: hasMount,
                  deviceName: _getDeviceName(devices, DeviceType.mount),
                ),
                _ExpandedStatusChip(
                  colors: colors,
                  icon: LucideIcons.focus,
                  label: 'Focuser',
                  isConnected: hasFocuser,
                  deviceName: _getDeviceName(devices, DeviceType.focuser),
                ),
                _ExpandedStatusChip(
                  colors: colors,
                  icon: LucideIcons.filter,
                  label: 'Filter wheel',
                  isConnected: hasFilterWheel,
                  deviceName: _getDeviceName(devices, DeviceType.filterWheel),
                ),
                _ExpandedStatusChip(
                  colors: colors,
                  icon: LucideIcons.crosshair,
                  label: 'Guider',
                  isConnected: hasGuider,
                  deviceName: _getDeviceName(devices, DeviceType.guider),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // Compact version
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CompactStatusIndicator(
          colors: colors,
          icon: LucideIcons.camera,
          isConnected: hasCamera,
          tooltip: hasCamera ? 'Camera Connected' : 'No Camera',
        ),
        const SizedBox(width: 4),
        _CompactStatusIndicator(
          colors: colors,
          icon: LucideIcons.locateFixed,
          isConnected: hasMount,
          tooltip: hasMount ? 'Mount Connected' : 'No Mount',
        ),
        const SizedBox(width: 4),
        _CompactStatusIndicator(
          colors: colors,
          icon: LucideIcons.focus,
          isConnected: hasFocuser,
          tooltip: hasFocuser ? 'Focuser Connected' : 'No Focuser',
        ),
        const SizedBox(width: 4),
        _CompactStatusIndicator(
          colors: colors,
          icon: LucideIcons.filter,
          isConnected: hasFilterWheel,
          tooltip:
              hasFilterWheel ? 'Filter Wheel Connected' : 'No Filter Wheel',
        ),
        const SizedBox(width: 4),
        _CompactStatusIndicator(
          colors: colors,
          icon: LucideIcons.crosshair,
          isConnected: hasGuider,
          tooltip: hasGuider ? 'Guider Connected' : 'No Guider',
        ),
      ],
    );
  }

  String? _getDeviceName(List<DeviceInfo> devices, DeviceType type) {
    try {
      return devices.firstWhere((d) => d.deviceType == type).name;
    } catch (_) {
      return null;
    }
  }

  Widget _buildLoadingState() {
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: colors.textMuted,
      ),
    );
  }

  Widget _buildErrorState() {
    return Tooltip(
      message: 'Could not load equipment status',
      child: Icon(
        LucideIcons.alertCircle,
        size: 16,
        color: colors.error,
      ),
    );
  }
}

/// Compact status indicator dot
class _CompactStatusIndicator extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final bool isConnected;
  final String tooltip;

  const _CompactStatusIndicator({
    required this.colors,
    required this.icon,
    required this.isConnected,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isConnected
              ? SkotiqDecorations.statusChip(
                  colors.success,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                  bordered: false,
                ).color
              : colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
          border: Border.all(
            color: isConnected
                ? colors.success.withValues(alpha: 0.3)
                : colors.border,
          ),
        ),
        child: Icon(
          icon,
          size: 12,
          color: isConnected ? colors.success : colors.textMuted,
        ),
      ),
    );
  }
}

/// Expanded status chip with device name
class _ExpandedStatusChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final bool isConnected;
  final String? deviceName;

  const _ExpandedStatusChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.isConnected,
    this.deviceName,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isConnected
            ? SkotiqDecorations.tintedBadge(
                colors.success,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              ).color
            : colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(
          color: isConnected
              ? colors.success.withValues(alpha: 0.3)
              : colors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isConnected ? colors.success : colors.textMuted,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    fontWeight: FontWeight.w500,
                    color: colors.textSecondary,
                  ),
                ),
                Text(
                  isConnected ? (deviceName ?? 'Connected') : 'Not Connected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize9,
                    color: isConnected ? colors.success : colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Derive driver type from device ID
/// Device IDs follow patterns:
/// - ASCOM: "ASCOM.Camera.Simulator"
/// - Alpaca: "alpaca://host:port/..." or starts with "alpaca:"
/// - INDI: "indi:DeviceName" or starts with "indi:"
/// - Native: vendor prefix like "zwo:", "qhy:", "playerone:", etc.
/// - Simulator: contains "Simulator" or starts with "sim:"
DriverType? _deriveDriverType(String deviceId) {
  final lower = deviceId.toLowerCase();

  // Check for explicit protocol prefixes
  if (lower.startsWith('ascom.') || lower.startsWith('ascom:')) {
    return DriverType.ascom;
  }
  if (lower.startsWith('alpaca:') || lower.startsWith('alpaca://')) {
    return DriverType.alpaca;
  }
  if (lower.startsWith('indi:')) {
    return DriverType.indi;
  }
  if (lower.startsWith('sim:') || lower.contains('simulator')) {
    return DriverType.simulator;
  }
  // Native SDK prefix (e.g., "native:zwo:0", "native:qhy:1")
  if (lower.startsWith('native:')) {
    return DriverType.native;
  }
  // PHD2 guider
  if (lower.startsWith('phd2:') ||
      lower.contains('phd2') ||
      lower.contains('phd 2')) {
    return DriverType.native;
  }

  // Check for native vendor prefixes (bare, without native: wrapper)
  const nativeVendorPrefixes = [
    'zwo:',
    'asi:',
    'qhy:',
    'playerone:',
    'svbony:',
    'atik:',
    'fli:',
    'moravian:',
    'touptek:',
    'skywatcher:',
    'ioptron:',
    'lx200:',
    'pegasus:',
  ];
  for (final prefix in nativeVendorPrefixes) {
    if (lower.startsWith(prefix)) {
      return DriverType.native;
    }
  }

  return null;
}

/// Provider for connected devices status - derives from individual device state providers
/// This ensures reactive updates when devices connect/disconnect
final connectedDevicesProvider = Provider<AsyncValue<List<DeviceInfo>>>((ref) {
  // Watch all individual device state providers for reactivity
  final cameraState = ref.watch(cameraStateProvider);
  final mountState = ref.watch(mountStateProvider);
  final focuserState = ref.watch(focuserStateProvider);
  final filterWheelState = ref.watch(filterWheelStateProvider);
  final guiderState = ref.watch(guiderStateProvider);

  final devices = <DeviceInfo>[];

  // Add camera if connected
  if (cameraState.connectionState == DeviceConnectionState.connected &&
      cameraState.deviceId != null) {
    devices.add(DeviceInfo(
      id: cameraState.deviceId!,
      name: _getDeviceDisplayName(cameraState.deviceName, cameraState.deviceId),
      deviceType: DeviceType.camera,
      driverType: _deriveDriverType(cameraState.deviceId!) ?? DriverType.native,
      description: '',
      driverVersion: '',
    ));
  }

  // Add mount if connected
  if (mountState.connectionState == DeviceConnectionState.connected &&
      mountState.deviceId != null) {
    devices.add(DeviceInfo(
      id: mountState.deviceId!,
      name: _getDeviceDisplayName(mountState.deviceName, mountState.deviceId),
      deviceType: DeviceType.mount,
      driverType: _deriveDriverType(mountState.deviceId!) ?? DriverType.native,
      description: '',
      driverVersion: '',
    ));
  }

  // Add focuser if connected
  if (focuserState.connectionState == DeviceConnectionState.connected &&
      focuserState.deviceId != null) {
    devices.add(DeviceInfo(
      id: focuserState.deviceId!,
      name:
          _getDeviceDisplayName(focuserState.deviceName, focuserState.deviceId),
      deviceType: DeviceType.focuser,
      driverType:
          _deriveDriverType(focuserState.deviceId!) ?? DriverType.native,
      description: '',
      driverVersion: '',
    ));
  }

  // Add filter wheel if connected
  if (filterWheelState.connectionState == DeviceConnectionState.connected &&
      filterWheelState.deviceId != null) {
    devices.add(DeviceInfo(
      id: filterWheelState.deviceId!,
      name: _getDeviceDisplayName(
          filterWheelState.deviceName, filterWheelState.deviceId),
      deviceType: DeviceType.filterWheel,
      driverType:
          _deriveDriverType(filterWheelState.deviceId!) ?? DriverType.native,
      description: '',
      driverVersion: '',
    ));
  }

  // Add guider if connected
  if (guiderState.connectionState == DeviceConnectionState.connected &&
      guiderState.deviceId != null) {
    devices.add(DeviceInfo(
      id: guiderState.deviceId!,
      name: _getDeviceDisplayName(guiderState.deviceName, guiderState.deviceId),
      deviceType: DeviceType.guider,
      driverType: _deriveDriverType(guiderState.deviceId!) ?? DriverType.native,
      description: '',
      driverVersion: '',
    ));
  }

  return AsyncValue.data(devices);
});
