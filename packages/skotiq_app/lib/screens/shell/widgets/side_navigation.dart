import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../shell_navigation.dart';
import 'rig_card.dart';
import 'window_chrome.dart';

/// One rail row: a destination, or the heading above a group of them.
sealed class SideNavEntry {
  const SideNavEntry();
}

class SideNavGroupHeading extends SideNavEntry {
  final String label;
  const SideNavGroupHeading(this.label);
}

class SideNavTab extends SideNavEntry {
  final IconData icon;
  final String label;

  /// Index into [ShellNavigation.primaryDestinations] — the rail's selection
  /// index. Carried explicitly because the group headings make the rendered
  /// row position and the destination index different numbers.
  final int index;

  const SideNavTab({
    required this.icon,
    required this.label,
    required this.index,
  });
}

/// The rail's rows, in order, with a heading before each group (04 §3.2).
List<SideNavEntry> sideNavigationEntries(BuildContext context) {
  final l10n = context.l10n;
  final entries = <SideNavEntry>[];
  ShellNavGroup? currentGroup;
  for (var i = 0; i < ShellNavigation.primaryDestinations.length; i++) {
    final dest = ShellNavigation.primaryDestinations[i];
    if (dest.group != currentGroup) {
      currentGroup = dest.group;
      entries.add(SideNavGroupHeading(currentGroup.label(l10n)));
    }
    entries.add(
      SideNavTab(icon: dest.icon, label: dest.label(l10n), index: i),
    );
  }
  return entries;
}

/// Every rail destination, ungrouped — the tutorial keys index by this.
List<SideNavTab> sideNavigationTabs(BuildContext context) => [
      for (final entry in sideNavigationEntries(context))
        if (entry is SideNavTab) entry,
    ];

/// The left sidebar (the window's own pane, g1-glass).
///
/// 64 px of icons by default, 220 px with labels and group headings when
/// expanded. It runs the FULL window height: the chrome header (lockup,
/// command field, drag strip) at the top, the destinations in the middle, and
/// the Rig card pinned to the bottom.
///
/// When the window is too short for the destinations and the collapse toggle
/// at full size (1443 x 760 with the rail open), the rail compacts: 32 px
/// items and tighter group gaps. Only if that still does not fit does the
/// list scroll, so no item is left half hidden behind the toggle.
///
/// `surface`-toned — a tonal step lighter than the `background` main area —
/// with a faint wash of the user's accent at the top-left corner that follows
/// the lockup's own accent (red in red night). There is no border on the
/// trailing edge: the slate's regions are separated by tone, not lines.
class SideNavigation extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;

  /// Optional GlobalKeys for tutorial targeting, indexed by destination (not
  /// by rendered row — the group headings are not targets).
  final List<GlobalKey?>? tutorialKeys;

  const SideNavigation({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.isExpanded,
    required this.onToggleExpanded,
    this.tutorialKeys,
  });

  /// The gap between two groups when the rail is collapsed and there is no
  /// heading to separate them.
  static const double _collapsedGroupGap = 14.0;

  /// Space above a group heading in the expanded rail. Below it is
  /// [SkotiqTokens.spaceXs].
  static const double _headingSpaceAbove = 10.0;

  /// Rail items sit 2 px apart; anything more and nine of them stop reading as
  /// one list.
  static const double _itemGap = 2.0;

  /// [_collapsedGroupGap] and [_headingSpaceAbove] in a compact rail.
  static const double _collapsedGroupGapCompact = 8.0;
  static const double _headingSpaceAboveCompact = 4.0;

  /// The height the destinations, their headings and the collapse toggle
  /// need at the given density.
  @visibleForTesting
  static double contentHeight({
    required List<SideNavEntry> entries,
    required bool isExpanded,
    required bool compact,
    required double headingTextHeight,
  }) {
    final item = compact
        ? ShellChromeMetrics.railItemSizeCompact
        : ShellChromeMetrics.railItemSize;
    var height = 0.0;
    for (var row = 0; row < entries.length; row++) {
      switch (entries[row]) {
        case SideNavGroupHeading():
          if (!isExpanded) {
            if (row > 0) {
              height +=
                  compact ? _collapsedGroupGapCompact : _collapsedGroupGap;
            }
          } else {
            if (row > 0) {
              height +=
                  compact ? _headingSpaceAboveCompact : _headingSpaceAbove;
            }
            height += headingTextHeight + SkotiqTokens.spaceXs;
          }
        case SideNavTab():
          height += item + _itemGap;
      }
    }
    // The list's bottom padding, then the toggle and its own padding.
    return height + SkotiqTokens.spaceSm + item + SkotiqTokens.spaceSm;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final entries = sideNavigationEntries(context);
    final badgedRoutes = _badgedRoutes(ref);

    return AnimatedContainer(
      duration: animationDuration(context, SkotiqTokens.durationSmooth),
      curve: SkotiqTokens.curveStandard,
      width: isExpanded
          ? ShellChromeMetrics.railWidthExpanded
          : ShellChromeMetrics.railWidthCollapsed,
      decoration: BoxDecoration(color: colors.surface),
      // Clipped because the width animates: mid-transition the 220 px row's
      // label is wider than the box it is animating into, and an unclipped
      // overflow paints it across the page body.
      child: ClipRect(
        child: Stack(
          children: [
            // The accent wash at the top-left corner — `primary` at ~10%
            // alpha, gone by 70% of the radius, so it follows whatever accent
            // the operator chose (including red night) the way the lockup
            // does. Decorative: the pane's identity comes through the lockup.
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topLeft,
                        radius: 1.6,
                        colors: [
                          colors.primary.withValues(alpha: 0.10),
                          colors.primary.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.7],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Brand, the palette field, and the strip that drags the
                // window (with room for macOS traffic lights).
                SidebarChromeHeader(isExpanded: isExpanded),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final headingText = TextPainter(
                        text: const TextSpan(
                          text: 'X',
                          style: SkotiqTypography.eyebrow,
                        ),
                        textScaler: MediaQuery.textScalerOf(context),
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                      )..layout();
                      final compact = contentHeight(
                            entries: entries,
                            isExpanded: isExpanded,
                            compact: false,
                            headingTextHeight: headingText.height,
                          ) >
                          constraints.maxHeight;
                      headingText.dispose();
                      final itemHeight = compact
                          ? ShellChromeMetrics.railItemSizeCompact
                          : ShellChromeMetrics.railItemSize;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ListView(
                              key: const ValueKey<String>('sideNav.list'),
                              padding: const EdgeInsets.fromLTRB(
                                SkotiqTokens.spaceMd,
                                0,
                                SkotiqTokens.spaceMd,
                                SkotiqTokens.spaceSm,
                              ),
                              children: [
                                for (var row = 0; row < entries.length; row++)
                                  _buildEntry(
                                    context,
                                    entries,
                                    row,
                                    badgedRoutes,
                                    compact: compact,
                                  ),
                              ],
                            ),
                          ),

                          // The collapse toggle is a rail item like any other,
                          // at the foot of the list. It is NAMED for what the
                          // tap does, not for the glyph: "Expand navigation"
                          // while collapsed.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              SkotiqTokens.spaceMd,
                              0,
                              SkotiqTokens.spaceMd,
                              SkotiqTokens.spaceSm,
                            ),
                            child: NavItem(
                              key: const ValueKey<String>('sideNav.toggle'),
                              icon: isExpanded
                                  ? LucideIcons.panelLeftClose
                                  : LucideIcons.panelLeft,
                              label: isExpanded
                                  ? '${l10n.text('collapse')} navigation'
                                  : 'Expand navigation',
                              isSelected: false,
                              isExpanded: isExpanded,
                              height: itemHeight,
                              onTap: onToggleExpanded,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                // The Rig card: run state, one row per device, the in-flight
                // operation strip and the save path — everything the old
                // bottom instrument bar carried.
                RigCard(isExpanded: isExpanded),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(
    BuildContext context,
    List<SideNavEntry> entries,
    int row,
    Set<String> badgedRoutes, {
    required bool compact,
  }) {
    final entry = entries[row];
    switch (entry) {
      case SideNavGroupHeading():
        // Collapsed there is no room for the word, so the group reads as a
        // gap instead. The first group gets neither: it needs no separation
        // from the rail's top edge.
        if (!isExpanded) {
          return SizedBox(
            height: row == 0
                ? 0
                : compact
                    ? _collapsedGroupGapCompact
                    : _collapsedGroupGap,
          );
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(
            _NavItemMetrics.iconInset,
            row == 0
                ? 0
                : compact
                    ? _headingSpaceAboveCompact
                    : _headingSpaceAbove,
            _NavItemMetrics.iconInset,
            SkotiqTokens.spaceXs,
          ),
          child: Text(
            entry.label.toUpperCase(),
            style: SkotiqTypography.eyebrow.copyWith(
              color: SkotiqColors.of(context).textMuted,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        );
      case SideNavTab():
        final destination = ShellNavigation.primaryDestinations[entry.index];
        final button = NavItem(
          key: tutorialKeys != null && entry.index < tutorialKeys!.length
              ? tutorialKeys![entry.index]
              : null,
          icon: entry.icon,
          label: entry.label,
          isSelected: entry.index == currentIndex,
          isExpanded: isExpanded,
          hasBadge: badgedRoutes.contains(destination.route),
          height: compact
              ? ShellChromeMetrics.railItemSizeCompact
              : ShellChromeMetrics.railItemSize,
          onTap: () => onTabSelected(entry.index),
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: _itemGap),
          // Collapsed, the label is the only thing that says where the glyph
          // leads, so it becomes the tooltip. Expanded, the label is on
          // screen and a tooltip repeating it is noise.
          child: isExpanded
              ? button
              : SkotiqTooltip(
                  message: entry.label,
                  waitDuration: ShellChromeMetrics.railTooltipDelay,
                  showArrow: false,
                  position: SkotiqTooltipPosition.right,
                  child: button,
                ),
        );
    }
  }

  /// The rail items carrying the attention dot right now.
  ///
  /// Two cases, both from 04 §3.1: Equipment while no device is connected, and
  /// Weather while conditions are unsafe. Both are read from the providers the
  /// screens themselves read, so the dot cannot disagree with the screen.
  Set<String> _badgedRoutes(WidgetRef ref) {
    final routes = <String>{};
    if (!ref.watch(railAnyDeviceConnectedProvider)) routes.add('/equipment');
    if (ref.watch(railWeatherUnsafeProvider)) routes.add('/weather');
    return routes;
  }
}

/// Whether ANY device is attached, for the Equipment dot.
///
/// A provider rather than four `ref.watch`es inside the rail, so the rail
/// rebuilds when the ANSWER changes rather than on any field of any device
/// state changing: a slewing mount must not repaint the navigation.
final railAnyDeviceConnectedProvider = Provider<bool>((ref) {
  return [
    ref.watch(cameraStateProvider.select((s) => s.connectionState)),
    ref.watch(mountStateProvider.select((s) => s.connectionState)),
    ref.watch(guiderStateProvider.select((s) => s.connectionState)),
    ref.watch(focuserStateProvider.select((s) => s.connectionState)),
  ].any((s) => s == DeviceConnectionState.connected);
});

/// Whether conditions are unsafe, for the Weather dot.
///
/// Narrowed to one bool on purpose. The rail wants a verdict, not the safety
/// subsystem: watching `weatherSafetyProvider` from the rail builds the whole
/// notifier — with its evaluation timers and its alert subscription — in every
/// context that renders navigation, which includes widget tests that are about
/// nothing but the rail's labels.
final railWeatherUnsafeProvider = Provider<bool>((ref) {
  return ref.watch(
    weatherSafetyProvider.select((s) => s.status == WeatherSafetyStatus.unsafe),
  );
});

/// The one NavItem metric the rail needs to align its own group headings with
/// the item glyphs beneath them.
abstract final class _NavItemMetrics {
  /// (railItemSize - 18) / 2, the same derivation NavItem uses.
  static const double iconInset = (ShellChromeMetrics.railItemSize - 18.0) / 2;
}
