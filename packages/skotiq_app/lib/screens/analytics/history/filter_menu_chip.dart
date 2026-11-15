import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A filter chip that opens a menu of [entries] under itself.
class FilterMenuChip<T> extends StatelessWidget {
  const FilterMenuChip({
    required this.label,
    required this.name,
    required this.entries,
    required this.selected,
    required this.onSelected,
    this.roomy = false,
  });

  final String label;

  /// What the control is, for a reader that cannot see the menu it opens.
  final String name;
  final List<(T, String)> entries;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Gives the chip a 48 px touch target (phone).
  final bool roomy;

  static const double _touchTarget = 48;

  Future<void> _open(BuildContext context) async {
    final colors = SkotiqColors.of(context);
    final box = context.findRenderObject()! as RenderBox;
    final picked = await showMenu<(T,)>(
      context: context,
      position: menuPositionFromRect(
        context,
        box.localToGlobal(Offset.zero) & box.size,
      ),
      color: colors.surfaceElevated,
      items: [
        for (final (value, text) in entries)
          PopupMenuItem<(T,)>(
            value: (value,),
            child: Text(
              text,
              style: SkotiqTypography.bodySm.copyWith(
                color: value == selected ? colors.primary : colors.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (picked != null) onSelected(picked.$1);
  }

  @override
  Widget build(BuildContext context) {
    void open() => _open(context);
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      label: '$name: $label',
      onTap: open,
      child: ExcludeSemantics(
        child: roomy
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: open,
                child: SizedBox(
                  height: _touchTarget,
                  child: Center(
                    widthFactor: 1,
                    child: IgnorePointer(
                      child: SkotiqFilterChip(
                        label: label,
                        trailingIcon: LucideIcons.chevronDown,
                        onTap: open,
                      ),
                    ),
                  ),
                ),
              )
            : SkotiqFilterChip(
                label: label,
                trailingIcon: LucideIcons.chevronDown,
                onTap: open,
              ),
      ),
    );
  }
}
