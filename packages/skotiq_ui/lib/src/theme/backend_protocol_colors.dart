import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart' show DriverType;
import 'skotiq_colors.dart';

/// Domain-specific hues for equipment driver backends.
///
/// Static constants hold fixed brand hues. Resolver methods take
/// [SkotiqColors] and map to semantic palette tokens where possible.
/// Follow this pattern for new domain color helpers.
abstract final class BackendProtocolColors {
  BackendProtocolColors._();

  /// Muted violet for INDI — distinct from info/warning/success without
  /// the saturation of legacy #9333EA.
  static const Color indi = Color(0xFF8575A3);

  /// Resolves a backend driver to a display color using [colors] semantics.
  static Color forBackend(DriverType backend, [SkotiqColors? colors]) {
    final palette = colors ?? SkotiqColors.dark;
    return switch (backend) {
      DriverType.native => palette.success,
      DriverType.ascom => palette.info,
      DriverType.alpaca => palette.warning,
      DriverType.indi => indi,
      DriverType.simulator => palette.textMuted,
    };
  }
}
