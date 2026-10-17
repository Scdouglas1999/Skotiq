import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../shell_navigation.dart';

/// The narrow shell's navigation (04-shell §3.3).
///
/// Five slots, 64 px: Tonight, Imaging, Sequencer, Guiding, More. Four of them
/// route; the fifth opens a sheet holding everything without a slot.
///
/// It is the ONLY bottom chrome below the tablet breakpoint — the instrument
/// bar is not mounted there at all — so it does not share the edge with a
/// second bar the way the six-slot version did.
class SkotiqBottomNavigation extends StatelessWidget {
  final String currentRoute;
  final ValueChanged<String> onRouteSelected;

  const SkotiqBottomNavigation({
    super.key,
    required this.currentRoute,
    required this.onRouteSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final currentPath = currentRoute.split('?').first;

    final overflowIsCurrent = ShellNavigation.overflowDestinations.any(
      (d) => ShellNavigation.locationIsUnder(currentPath, d.route),
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: BottomNavMetrics.barHeight,
          child: Row(
            children: [
              for (final dest in ShellNavigation.bottomNavigationDestinations)
                Expanded(
                  child: _BottomNavItem(
                    icon: dest.icon,
                    label: dest.bottomNavLabel(l10n),
                    // Sub-route aware: the image-ready deep link
                    // (/imaging/preview/:id) renders the Imaging screen, so
                    // the Imaging slot must own it. Exact matching left the
                    // whole bar unlit on those routes.
                    isSelected: ShellNavigation.locationIsUnder(
                      currentPath,
                      dest.route,
                    ),
                    colors: colors,
                    onTap: () => onRouteSelected(dest.route),
                  ),
                ),
              Expanded(
                child: _BottomNavItem(
                  icon: LucideIcons.menu,
                  label: l10n.text('navMore'),
                  isSelected: overflowIsCurrent,
                  colors: colors,
                  onTap: () => _showMoreSheet(context, l10n, colors),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The sheet behind "More": Plan, Equipment, Weather, Darkroom, Analytics
  /// and Settings, in rail order.
  ///
  /// Every top-level surface is reachable on a phone this way, which is what
  /// lets the bar hold five slots instead of seven — five is what a thumb can
  /// hit without looking.
  void _showMoreSheet(
    BuildContext context,
    SkotiqLocalizations l10n,
    SkotiqColors colors,
  ) {
    final currentPath = currentRoute.split('?').first;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.surface,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final dest in ShellNavigation.overflowDestinations)
                Builder(
                  builder: (context) {
                    final isCurrent = ShellNavigation.locationIsUnder(
                      currentPath,
                      dest.route,
                    );
                    return ListTile(
                      leading: Icon(
                        dest.icon,
                        color:
                            isCurrent ? colors.primary : colors.textSecondary,
                      ),
                      title: Text(
                        dest.label(l10n),
                        style: SkotiqTypography.body.copyWith(
                          color:
                              isCurrent ? colors.primary : colors.textPrimary,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      selected: isCurrent,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onRouteSelected(dest.route);
                      },
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// One slot: a 48 x 28 pill behind a 21 px glyph, with an 11 px label under it.
///
/// The pill is what carries selection, not a colour change on the glyph alone:
/// at arm's length in the dark a tinted icon and an untinted one are the same
/// icon, and the filled shape is legible from further away than the colour is.
class _BottomNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    // Same annotation the rail's NavItem carries, because the bar is the
    // rail's phone-width replacement and has to answer the same three
    // questions. A bare InkWell contributes a tap action and nothing else:
    // measured on the running app at 420x900, every destination came back as
    // `panel` with states [focusable, showing, visible] — no role, no
    // `selected` on the one the operator is standing in, and no `enabled`,
    // which reads to assistive tech as a disabled control. `enabled` is
    // published only when the field is given, so it is given.
    return Semantics(
      enabled: true,
      button: true,
      selected: isSelected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: BottomNavMetrics.itemSelectionAnimationDuration,
                curve: SkotiqTokens.curveStandard,
                width: BottomNavMetrics.itemPillWidth,
                height: BottomNavMetrics.itemPillHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? colors.primary.withValues(
                          alpha: SkotiqTokens.opacityAccentTint,
                        )
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    BottomNavMetrics.itemBorderRadius,
                  ),
                ),
                child: Icon(
                  icon,
                  size: BottomNavMetrics.itemIconSize,
                  color: isSelected ? colors.primary : colors.textSecondary,
                ),
              ),
              const SizedBox(height: BottomNavMetrics.itemIconLabelGap),
              // FittedBox: a label a shade too wide for its slot ("Sequence",
              // Spanish "Secuencia") scales down a few percent instead of
              // ellipsizing — an ellipsis in a five-slot bar reads as broken,
              // a 5% smaller glyph is invisible.
              // The Semantics above already carries this word. Left to speak
              // for itself the Text merges into that node and a screen reader
              // says "More More"; excluded HERE rather than with
              // `excludeSemantics` on the wrapper, which would also drop the
              // InkWell's tap action and leave the slot visible but
              // unactivatable.
              ExcludeSemantics(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: _labelStyle.copyWith(
                      color: isSelected ? colors.primary : colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 11 px / 500 (04 §3.3). `captionSm` is 12; the bar's five labels need the
  /// extra pixel back.
  // TODO(observatory): promote to SkotiqTypography.navLabel at merge.
  static const TextStyle _labelStyle = TextStyle(
    fontFamily: SkotiqTypography.fontFamily,
    fontSize: BottomNavMetrics.itemLabelFontSize,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: 0.2,
  );
}
