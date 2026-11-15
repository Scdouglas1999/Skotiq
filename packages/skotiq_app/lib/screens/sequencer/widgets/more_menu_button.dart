import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// One entry of a [MoreMenuButton].
class MoreMenuEntry<T> {
  const MoreMenuEntry(this.value, this.label, {this.destructive = false});

  final T value;
  final String label;

  /// Painted in the error color: the entry deletes something.
  final bool destructive;
}

/// The "more" icon button at the end of a row or card: it opens a menu of
/// [entries] under itself and reports the picked value.
class MoreMenuButton<T> extends StatelessWidget {
  const MoreMenuButton({
    super.key,
    required this.tooltip,
    required this.entries,
    required this.onSelected,
  });

  /// Names what the actions act on: "More actions for M31 LRGB".
  final String tooltip;
  final List<MoreMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;

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
        for (final entry in entries)
          PopupMenuItem<(T,)>(
            value: (entry.value,),
            child: Text(
              entry.label,
              style: SkotiqTypography.bodySm.copyWith(
                color: entry.destructive ? colors.error : colors.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (picked != null) onSelected(picked.$1);
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      icon: SkotiqIcons.more,
      tooltip: tooltip,
      onPressed: () => _open(context),
    );
  }
}
