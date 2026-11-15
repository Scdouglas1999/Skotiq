import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_icons.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/menu_position.dart';
import '../utils/touch_target.dart';
import 'skotiq_chip.dart';
import 'skotiq_icon_button.dart';

/// One row of a menu opened by [SkotiqMenuChip] or [SkotiqMenuButton].
sealed class SkotiqMenuEntry<T> {
  const SkotiqMenuEntry();
}

/// A row the operator can pick.
final class SkotiqMenuChoice<T> extends SkotiqMenuEntry<T> {
  const SkotiqMenuChoice(
    this.value,
    this.label, {
    this.checked = false,
    this.destructive = false,
  });

  final T value;
  final String label;

  /// Carries a check: the value the control is on now, or one of several
  /// picked.
  final bool checked;

  /// Painted in the error color: the row deletes something.
  final bool destructive;
}

/// A hairline between two runs of rows.
final class SkotiqMenuDivider<T> extends SkotiqMenuEntry<T> {
  const SkotiqMenuDivider();
}

/// Opens [entries] below the control that owns [anchor] and returns the
/// value picked, as a record so a null value and a dismissed menu stay apart.
///
/// Pass the control's own context (a [Builder] around it), not an
/// ancestor's: the menu is placed against the box [anchor] belongs to.
Future<(T,)?> showSkotiqMenu<T>(
  BuildContext anchor,
  List<SkotiqMenuEntry<T>> entries,
) {
  final colors = anchor.skotiqColors;
  return showMenu<(T,)>(
    context: anchor,
    position: menuPositionBelowWidget(anchor),
    items: <PopupMenuEntry<(T,)>>[
      for (final entry in entries)
        switch (entry) {
          SkotiqMenuDivider<T>() => const PopupMenuDivider(),
          SkotiqMenuChoice<T>() => PopupMenuItem<(T,)>(
            value: (entry.value,),
            height: SkotiqTokens.buttonHeightLg,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    entry.label,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.body.copyWith(
                      color: entry.destructive
                          ? colors.error
                          : colors.textPrimary,
                    ),
                  ),
                ),
                if (entry.checked)
                  Icon(
                    LucideIcons.check,
                    size: SkotiqTokens.iconSm,
                    color: colors.primary,
                  ),
              ],
            ),
          ),
        },
    ],
  );
}

/// A [SkotiqFilterChip] that opens a menu of [entries] below itself and
/// reports the value picked.
///
/// The chip's label is the caller's ("Sort: score"), so it can name the field
/// and the value together.
class SkotiqMenuChip<T> extends StatelessWidget {
  const SkotiqMenuChip({
    super.key,
    required this.label,
    required this.entries,
    required this.onSelected,
    this.icon,
    this.name,
    this.roomy = false,
  });

  final String label;
  final List<SkotiqMenuEntry<T>> entries;

  /// Called with the picked value. Null disables the chip.
  final ValueChanged<T>? onSelected;

  final IconData? icon;

  /// What the control is ("Sort order"), read before [label] by a screen
  /// reader, which cannot see the menu it opens.
  final String? name;

  /// Gives the chip a [SkotiqTokens.minTouchTarget] hit area whatever the
  /// platform, for a phone-width layout. Touch platforms always get it.
  final bool roomy;

  @override
  Widget build(BuildContext context) {
    final select = onSelected;
    return Builder(
      builder: (anchor) {
        Future<void> open() async {
          final picked = await showSkotiqMenu<T>(anchor, entries);
          if (picked != null) select!(picked.$1);
        }

        final chip = SkotiqFilterChip(
          label: label,
          icon: icon,
          trailingIcon: LucideIcons.chevronDown,
          onTap: select == null ? null : open,
        );
        final sized = roomy || SkotiqTouchTarget.isTouch(context)
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: select == null ? null : open,
                child: SizedBox(
                  height: SkotiqTokens.minTouchTarget,
                  child: Center(
                    widthFactor: 1,
                    child: IgnorePointer(child: chip),
                  ),
                ),
              )
            : chip;
        return Semantics(
          container: true,
          button: true,
          enabled: select != null,
          label: name == null ? label : '$name: $label',
          onTap: select == null ? null : open,
          child: ExcludeSemantics(child: sized),
        );
      },
    );
  }
}

/// The icon button at the end of a row, card or header that opens a menu of
/// [entries] below itself: "more" by default.
class SkotiqMenuButton<T> extends StatelessWidget {
  const SkotiqMenuButton({
    super.key,
    required this.tooltip,
    required this.entries,
    required this.onSelected,
    this.icon = SkotiqIcons.more,
    this.size = IconButtonSize.md,
  });

  /// Names what the actions act on: "More actions for M31 LRGB".
  final String tooltip;
  final List<SkotiqMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final IconData icon;
  final IconButtonSize size;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (anchor) => SkotiqIconButton(
        icon: icon,
        tooltip: tooltip,
        size: size,
        onPressed: () async {
          final picked = await showSkotiqMenu<T>(anchor, entries);
          if (picked != null) onSelected(picked.$1);
        },
      ),
    );
  }
}
