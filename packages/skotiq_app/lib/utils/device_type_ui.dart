import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// How a device type looks: the one icon and accent table for the app.
extension DeviceTypeUi on DeviceType {
  IconData get icon => switch (this) {
    DeviceType.camera => LucideIcons.camera,
    DeviceType.mount => LucideIcons.compass,
    DeviceType.focuser => LucideIcons.focus,
    DeviceType.filterWheel => LucideIcons.disc,
    DeviceType.guider => LucideIcons.crosshair,
    DeviceType.rotator => LucideIcons.rotateCw,
    DeviceType.dome => LucideIcons.home,
    DeviceType.weather => LucideIcons.cloudSun,
    DeviceType.safetyMonitor => LucideIcons.shieldCheck,
    DeviceType.switch_ => LucideIcons.toggleRight,
    DeviceType.coverCalibrator => LucideIcons.lamp,
  };

  /// One accent per device category. Status colors are left to the
  /// connection state, so a card's border is never ambiguous.
  Color accentColor(SkotiqColors colors) => switch (this) {
    DeviceType.camera => colors.primary,
    DeviceType.mount ||
    DeviceType.rotator ||
    DeviceType.dome => colors.warning,
    DeviceType.focuser ||
    DeviceType.filterWheel ||
    DeviceType.coverCalibrator ||
    DeviceType.switch_ => colors.accent,
    DeviceType.guider || DeviceType.weather => colors.info,
    DeviceType.safetyMonitor => colors.success,
  };
}
