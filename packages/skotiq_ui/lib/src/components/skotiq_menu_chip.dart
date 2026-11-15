import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/menu_position.dart';
import 'skotiq_chip.dart';

/// One choice of a [SkotiqMenuChip].
@immutable
class SkotiqMenuChoice<T> {
  const SkotiqMenuChoice(this.value, this.label);

  final T value;
  final String label;
}

/// A [SkotiqFilterChip] that opens a menu of [choices] below itself and
/// reports the one picked. The current [value] carries a check in the menu.
///
/// The chip's label is the caller's ("Sort: Score"), so it can name the field
/// and the value together.
class SkotiqMenuChip<T> extends StatelessWidget {
  const SkotiqMenuChip({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onSelected,
    this.icon,
  });

  final String label;
  final T value;
  final List<SkotiqMenuChoice<T>> choices;

  /// Called with the picked value. Null disables the chip.
  final ValueChanged<T>? onSelected;

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final select = onSelected;
    return Builder(
      builder: (anchor) => SkotiqFilterChip(
        label: label,
        icon: icon,
        trailingIcon: LucideIcons.chevronDown,
        onTap: select == null
            ? null
            : () async {
                final picked = await showMenu<T>(
                  context: anchor,
                  position: menuPositionBelowWidget(anchor),
                  items: <PopupMenuEntry<T>>[
                    for (final choice in choices)
                      _item(anchor, choice, checked: choice.value == value),
                  ],
                );
                if (picked != null) select(picked);
              },
      ),
    );
  }

  static PopupMenuItem<T> _item<T>(
    BuildContext context,
    SkotiqMenuChoice<T> choice, {
    required bool checked,
  }) {
    final colors = context.skotiqColors;
    return PopupMenuItem<T>(
      value: choice.value,
      height: SkotiqTokens.buttonHeightLg,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              choice.label,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.body.copyWith(color: colors.textPrimary),
            ),
          ),
          if (checked)
            Icon(
              LucideIcons.check,
              size: SkotiqTokens.iconSm,
              color: colors.primary,
            ),
        ],
      ),
    );
  }
}
