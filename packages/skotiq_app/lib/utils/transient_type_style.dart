import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The single presentation of a [TransientType]: one glyph, one severity
/// colour, one name.
///
/// Every alert surface reads this class, so one type cannot be named or
/// coloured two ways across screens.
///
/// ## The severity palette
///
/// [color] is banded off the priority the app already computes in
/// `TransientAlertService._calculatePriority` (supernova 1, gamma-ray burst 2,
/// nova 3, cataclysmic 4, comet 5, asteroid 6, variable star 7, other 8), so
/// the colour a user sees and the ordering the queue applies cannot drift
/// apart:
///
/// | Priority | Colour            | Types                        |
/// |----------|-------------------|------------------------------|
/// | 1-2      | `error`           | supernova, gamma-ray burst   |
/// | 3-4      | `warning`         | nova, cataclysmic            |
/// | 5-6      | `info`            | comet, asteroid              |
/// | 7        | `accent`          | variable star                |
/// | 8        | `textMuted`       | other                        |
abstract final class TransientTypeStyle {
  static IconData icon(TransientType type) => switch (type) {
        TransientType.nova => SkotiqIcons.star,
        TransientType.supernova => SkotiqIcons.sparkle,
        TransientType.comet => LucideIcons.orbit,
        TransientType.cataclysmic => SkotiqIcons.bolt,
        TransientType.asteroid => SkotiqIcons.circle,
        TransientType.variableStar => SkotiqIcons.activity,
        TransientType.gammaRayBurst => LucideIcons.flame,
        TransientType.other => SkotiqIcons.help,
      };

  static Color color(TransientType type, SkotiqColors colors) => switch (type) {
        TransientType.supernova || TransientType.gammaRayBurst => colors.error,
        TransientType.nova || TransientType.cataclysmic => colors.warning,
        TransientType.comet || TransientType.asteroid => colors.info,
        TransientType.variableStar => colors.accent,
        TransientType.other => colors.textMuted,
      };

  /// The full name, for headings and detail rows.
  static String label(TransientType type) => switch (type) {
        TransientType.nova => 'Nova',
        TransientType.supernova => 'Supernova',
        TransientType.comet => 'Comet',
        TransientType.cataclysmic => 'Cataclysmic Variable',
        TransientType.asteroid => 'Asteroid',
        TransientType.variableStar => 'Variable Star',
        TransientType.gammaRayBurst => 'Gamma-Ray Burst',
        TransientType.other => 'Other',
      };

  /// The abbreviated name, for filter chips and settings rows where the full
  /// name would wrap.
  static String shortLabel(TransientType type) => switch (type) {
        TransientType.cataclysmic => 'Cataclysmic',
        TransientType.variableStar => 'Variable',
        TransientType.gammaRayBurst => 'GRB',
        _ => label(type),
      };
}
