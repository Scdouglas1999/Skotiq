part of '../sequence_toolbar.dart';

/// A single toolbar action. `isDivider == true` represents a visual
/// separator between groups (inline) or the start of a new section in
/// the overflow menu. Both renderings are driven by the same data so a hidden
/// button never silently disappears.
class _ToolbarAction {
  final IconData? icon;
  final String? label;
  final VoidCallback? onPressed;
  final bool isDivider;

  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  }) : isDivider = false;

  const _ToolbarAction.divider()
      : icon = null,
        label = null,
        onPressed = null,
        isDivider = true;
}

/// The canvas bar's "more" menu: every secondary action, in one popup.
///
/// The anchor is a [SkotiqIconButton], not `PopupMenuButton`'s own icon.
/// PopupMenuButton sizes its anchor from `kMinInteractiveDimension` (48) and
/// this button sits in a 44 px bar between two 28 px buttons — it cannot be
/// the one control that is twenty pixels taller than its neighbours, and on a
/// narrow canvas those twenty pixels are what overflowed the row. The menu is
/// opened with [showMenu] positioned on the button's own rect, so the popup
/// still hangs off the control the user pressed.
///
/// Entries are disabled-but-visible when an action's `onPressed` is null,
/// matching the inline behaviour.
class _ToolbarOverflowMenu extends StatelessWidget {
  final SkotiqColors colors;
  final List<_ToolbarAction> actions;

  const _ToolbarOverflowMenu({required this.colors, required this.actions});

  Future<void> _open(BuildContext context) async {
    final position = menuPositionBelowWidget(context);

    final items = <PopupMenuEntry<int>>[];
    for (var i = 0; i < actions.length; i++) {
      final a = actions[i];
      if (a.isDivider) {
        if (items.isNotEmpty) items.add(const PopupMenuDivider());
        continue;
      }
      items.add(
        PopupMenuItem<int>(
          value: i,
          enabled: a.onPressed != null,
          child: Row(
            children: [
              Icon(
                a.icon,
                size: 16,
                color: a.onPressed == null
                    ? colors.textMuted
                    : colors.textSecondary,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm + 2),
              Flexible(
                child: Text(
                  a.label!,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: a.onPressed == null
                        ? colors.textMuted
                        : colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) return;

    final chosen = await showMenu<int>(
      context: context,
      position: position,
      items: items,
    );
    if (chosen == null) return;
    actions[chosen].onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      icon: LucideIcons.moreHorizontal,
      tooltip: 'More actions',
      size: IconButtonSize.sm,
      onPressed: () => _open(context),
    );
  }
}
