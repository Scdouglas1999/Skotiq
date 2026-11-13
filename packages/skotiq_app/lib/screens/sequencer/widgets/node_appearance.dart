import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The glyph for a name from the icon vocabulary nodes, palette items and
/// snippets use ([NodeKind.icon], [SequenceNode.iconName], palette `icon`,
/// [TemplateSnippet.iconName]), or [fallback] for a name this build does not
/// draw.
IconData nodeIcon(String iconName, {IconData fallback = LucideIcons.box}) =>
    switch (iconName) {
      'activity' || 'analytics' => LucideIcons.activity,
      'aperture' => LucideIcons.aperture,
      'bell' => LucideIcons.bell,
      'camera' => LucideIcons.camera,
      'cast_connected' => LucideIcons.cast,
      'circle' => LucideIcons.circle,
      'clock' => LucideIcons.clock,
      'cloud-off' => LucideIcons.cloudOff,
      'code' => LucideIcons.code,
      'compass' => LucideIcons.compass,
      'crosshair' => LucideIcons.crosshair,
      'door-closed' => LucideIcons.doorClosed,
      'door-open' => LucideIcons.doorOpen,
      'filter' => LucideIcons.filter,
      'flame' => LucideIcons.flame,
      'focus' => LucideIcons.focus,
      'git-branch' => LucideIcons.gitBranch,
      'git-merge' => LucideIcons.gitMerge,
      'grid' => LucideIcons.grid,
      'home' => LucideIcons.home,
      'layers' => LucideIcons.layers,
      'lightbulb' => LucideIcons.lightbulb,
      'lightbulb-off' => LucideIcons.lightbulbOff,
      'lineChart' => LucideIcons.lineChart,
      'list' => LucideIcons.list,
      'move' => LucideIcons.move,
      'palette' => LucideIcons.palette,
      'parking-circle' => LucideIcons.parkingCircle,
      'puzzle' => LucideIcons.puzzle,
      'refresh-cw' => LucideIcons.refreshCw,
      'repeat' => LucideIcons.repeat,
      'rotate-cw' => LucideIcons.rotateCw,
      'scheduler' => LucideIcons.calendarClock,
      'settings' => LucideIcons.settings,
      'shield' => LucideIcons.shield,
      'shield-check' => LucideIcons.shieldCheck,
      'shuffle' => LucideIcons.shuffle,
      'snowflake' => LucideIcons.snowflake,
      'star' => LucideIcons.star,
      'target' => LucideIcons.target,
      'timer' => LucideIcons.timer,
      'unlock' => LucideIcons.unlock,
      'workflow' => LucideIcons.workflow,
      'wrench' => LucideIcons.wrench,
      'x-circle' => LucideIcons.xCircle,
      'zap' => LucideIcons.zap,
      _ => fallback,
    };

/// The tint of a node's glyph and summary chips, by category.
///
/// A category is not a status: the tint colours only the node's own glyph
/// and chips, never the row's chrome.
Color nodeCategoryTint(NodeCategory category, SkotiqColors colors) =>
    switch (category) {
      NodeCategory.instruction => colors.primary,
      NodeCategory.trigger => colors.warning,
      NodeCategory.logic => colors.accent,
      NodeCategory.target => colors.warning,
    };
