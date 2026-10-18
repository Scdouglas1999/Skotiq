part of '../connected_device_card.dart';

// Helper widgets

/// One measurement on a device panel: a mono value, an optional unit attached
/// to it, and a quiet label. A null [value] renders the em dash through
/// [Readout] — the card never invents a placeholder string.
class _DeviceMetric {
  final String? value;
  final String label;
  final String? unit;
  final Color? valueColor;

  _DeviceMetric({
    required this.value,
    required this.label,
    this.unit,
    this.valueColor,
  });
}

class _ActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final SkotiqColors colors;

  /// Hover text; for a disabled action, why it is disabled. Also read by
  /// assistive tech while the action is disabled.
  final String? tooltip;

  const _ActionButton({
    required this.label,
    required this.onTap,
    this.onLongPress,
    required this.colors,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onLongPress: onTap == null ? null : onLongPress,
      child: SkotiqButton(
        onPressed: onTap,
        label: label,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        semanticsHint: onTap == null ? tooltip : null,
      ),
    );
    final message = tooltip;
    if (message == null) return button;
    return SkotiqTooltip(message: message, child: button);
  }
}

class _FilterDropdown extends StatelessWidget {
  final List<String> filterNames;
  final int? currentPosition;
  final ValueChanged<int> onFilterSelected;
  final bool enabled;
  final SkotiqColors colors;

  const _FilterDropdown({
    required this.filterNames,
    required this.currentPosition,
    required this.onFilterSelected,
    this.enabled = true,
    required this.colors,
  });

  /// Width of the filter picker inside a device panel's action row.
  static const double width = 132.0;

  @override
  Widget build(BuildContext context) {
    if (filterNames.isEmpty) {
      return _ActionButton(
        label: 'No filters',
        onTap: null,
        colors: colors,
      );
    }

    final value = currentPosition != null &&
            currentPosition! >= 0 &&
            currentPosition! < filterNames.length
        ? filterNames[currentPosition!]
        : null;

    return SizedBox(
      width: width,
      child: SkotiqDropdown(
        value: value,
        items: filterNames,
        dense: true,
        onChanged: enabled
            ? (selected) {
                if (selected == null) return;
                final index = filterNames.indexOf(selected);
                if (index >= 0) onFilterSelected(index);
              }
            : null,
      ),
    );
  }
}
