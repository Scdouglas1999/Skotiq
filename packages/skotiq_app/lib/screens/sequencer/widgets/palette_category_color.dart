import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Resolve a palette category name to its swatch color. Plugin-contributed
/// categories (prefixed "Plugins / " or named "Plugins") all map to [accent]
/// and are matched BEFORE the literal cases so a plugin that names its
/// category "Target" doesn't accidentally adopt the warning color.
Color nodePaletteCategoryColor(String categoryName, SkotiqColors colors) {
  if (categoryName.startsWith('Plugins / ') || categoryName == 'Plugins') {
    return colors.accent;
  }
  switch (categoryName) {
    case 'Target':
      return colors.warning;
    case 'Imaging':
      return colors.primary;
    case 'Mount':
      return colors.info;
    case 'Focus':
      return colors.accent;
    // Camera shares the imaging family but gets the dedicated success token
    // so the legend swatch is distinguishable from Imaging.
    case 'Camera':
      return colors.success;
    case 'Logic':
      return colors.accent;
    case 'Timing':
      return colors.warning;
    case 'Utilities':
      return colors.textMuted;
    case 'Flat Panel':
      return colors.warning;
    case 'Dome':
      return colors.info;
    case 'Guiding':
      return colors.primary;
    case 'Science':
      return colors.accent;
    default:
      return colors.textSecondary;
  }
}
