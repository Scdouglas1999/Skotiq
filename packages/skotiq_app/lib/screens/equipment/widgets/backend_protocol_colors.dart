import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart' show DriverType;
import 'package:skotiq_ui/skotiq_ui.dart' show SkotiqColors;

/// Hues for equipment driver backends.
abstract final class BackendProtocolColors {
  BackendProtocolColors._();

  /// Muted violet for INDI — distinct from info/warning/success without
  /// the saturation of legacy #9333EA.
  static const Color indi = Color(0xFF8575A3);

  static Color forBackend(DriverType backend, SkotiqColors colors) {
    return switch (backend) {
      DriverType.native => colors.success,
      DriverType.ascom => colors.info,
      DriverType.alpaca => colors.warning,
      DriverType.indi => indi,
      DriverType.simulator => colors.textMuted,
    };
  }
}
