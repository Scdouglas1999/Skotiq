import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Single source of truth for node-palette glyphs and category colors.
///
/// The docked toolbox palette (`sequencer_screen_parts/node_palette.dart`), the
/// sidebar/mobile palette (`widgets/node_palette.dart`), the Insert
/// Above/Below picker and the tree color legend all route through these two
/// functions, so icons, colors and legend swatches stay in lock-step.

/// Resolve a palette/node `iconName` to its Lucide glyph. Unknown names fall
/// back to the generic box so a missing mapping degrades gracefully instead
/// of throwing.
IconData nodePaletteIconFor(String iconName) {
  switch (iconName) {
    case 'target':
      return LucideIcons.target;
    case 'camera':
      return LucideIcons.camera;
    case 'circle':
      return LucideIcons.circle;
    case 'shuffle':
      return LucideIcons.shuffle;
    case 'compass':
      return LucideIcons.compass;
    case 'crosshair':
      return LucideIcons.crosshair;
    case 'parking-circle':
      return LucideIcons.parkingCircle;
    case 'unlock':
      return LucideIcons.unlock;
    case 'focus':
      return LucideIcons.focus;
    case 'snowflake':
      return LucideIcons.snowflake;
    case 'flame':
      return LucideIcons.flame;
    case 'rotate-cw':
      return LucideIcons.rotateCw;
    case 'workflow':
      return LucideIcons.workflow;
    case 'repeat':
      return LucideIcons.repeat;
    case 'git-merge':
      return LucideIcons.gitMerge;
    case 'git-branch':
      return LucideIcons.gitBranch;
    case 'shield-check':
      return LucideIcons.shieldCheck;
    case 'clock':
      return LucideIcons.clock;
    case 'timer':
      return LucideIcons.timer;
    case 'wrench':
      return LucideIcons.wrench;
    case 'bell':
      return LucideIcons.bell;
    case 'code':
      return LucideIcons.code;
    case 'list':
      return LucideIcons.list;
    case 'aperture':
      return LucideIcons.aperture;
    case 'door-open':
      return LucideIcons.doorOpen;
    case 'door-closed':
      return LucideIcons.doorClosed;
    case 'lightbulb':
      return LucideIcons.lightbulb;
    case 'lightbulb-off':
      return LucideIcons.lightbulbOff;
    // SmartExposure uses the layered-stack glyph for its tabular editor.
    case 'layers':
      return LucideIcons.layers;
    case 'lineChart':
      return LucideIcons.lineChart;
    case 'analytics':
      return LucideIcons.activity;
    // Plugin-contributed nodes default to the puzzle-piece glyph.
    case 'puzzle':
      return LucideIcons.puzzle;
    default:
      return LucideIcons.box;
  }
}

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
