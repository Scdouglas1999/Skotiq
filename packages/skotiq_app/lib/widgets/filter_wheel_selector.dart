import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../utils/snackbar_helper.dart';

/// Style options for the filter wheel selector.
enum FilterSelectorStyle {
  /// Shows filters as colored circular buttons.
  buttons,

  /// Shows filters in a dropdown menu.
  dropdown
}

/// Reusable widget for filter wheel selection.
///
/// This eliminates duplicate filter selection implementations across screens.
/// Supports both button-based and dropdown-based selection styles.
class FilterWheelSelector extends ConsumerStatefulWidget {
  /// The style of filter selection UI to display.
  final FilterSelectorStyle style;

  /// Callback invoked when a filter is selected.
  final void Function(int position, String name)? onFilterSelected;

  /// Whether to use compact sizing.
  final bool compact;

  const FilterWheelSelector({
    super.key,
    this.style = FilterSelectorStyle.buttons,
    this.onFilterSelected,
    this.compact = false,
  });

  @override
  ConsumerState<FilterWheelSelector> createState() =>
      _FilterWheelSelectorState();

  /// Returns the display color for a filter based on its name.
  ///
  /// Common filter types are mapped to recognizable colors:
  /// - Red/R/Ha → Red
  /// - Green/G → Green
  /// - Blue/B → Blue
  /// - Lum/L/Clear → Grey
  /// - OIII/O3 → Teal
  /// - SII/S2 → Deep Orange
  /// - NII/N2 → Purple
  static Color getFilterColor(String name, {SkotiqColors? colors}) =>
      FilterColors.forName(name, colors: colors);
}

class _FilterWheelSelectorState extends ConsumerState<FilterWheelSelector> {
  Future<void> _selectFilter(int position) async {
    final state = ref.read(filterWheelStateProvider);
    if (state.connectionState != DeviceConnectionState.connected ||
        state.isMoving ||
        ref.read(sessionStateProvider).isAutofocusing) {
      return;
    }
    try {
      // Always use deviceService - it handles filter offsets
      await ref.read(deviceServiceProvider).setFilterWheelPosition(position);
      final fwState = ref.read(filterWheelStateProvider);
      if (widget.onFilterSelected != null &&
          fwState.filterNames.length > position) {
        widget.onFilterSelected!(position, fwState.filterNames[position]);
      }
    } catch (e) {
      if (mounted) context.showErrorSnackBar('Failed to change filter: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fwState = ref.watch(filterWheelStateProvider);
    final filterNames = fwState.filterNames;
    final currentPosition = fwState.currentPosition;
    final isMoving = fwState.isMoving;
    final controlsEnabled =
        fwState.connectionState == DeviceConnectionState.connected &&
            !isMoving &&
            !ref.watch(sessionStateProvider).isAutofocusing;

    // Don't show if no filters configured
    if (filterNames.isEmpty) return const SizedBox.shrink();

    if (widget.style == FilterSelectorStyle.dropdown) {
      final validPosition = currentPosition != null &&
          currentPosition >= 0 &&
          currentPosition < filterNames.length;
      return DropdownButton<int>(
        value: validPosition ? currentPosition : null,
        items: filterNames
            .asMap()
            .entries
            .map((e) => DropdownMenuItem(
                  value: e.key,
                  // Material's menu entries declare the button role but never
                  // the enabled state, and AT-SPI reads an absent enabled flag
                  // as disabled — so every filter in a live wheel announced
                  // itself as unavailable, with no mark on the mounted one.
                  child: Semantics(
                    enabled: controlsEnabled,
                    selected: e.key == currentPosition,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: FilterWheelSelector.getFilterColor(e.value,
                                colors: context.skotiqColors),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(e.value),
                      ],
                    ),
                  ),
                ))
            .toList(),
        onChanged: controlsEnabled
            ? (pos) => pos != null ? _selectFilter(pos) : null
            : null,
      );
    }

    // Button style
    return Wrap(
      spacing: widget.compact ? 4 : 8,
      runSpacing: widget.compact ? 4 : 8,
      children: filterNames
          .asMap()
          .entries
          .map((e) => _FilterButton(
                label: e.value,
                color: FilterWheelSelector.getFilterColor(e.value,
                    colors: context.skotiqColors),
                isSelected: currentPosition != null && e.key == currentPosition,
                compact: widget.compact,
                onTap: controlsEnabled ? () => _selectFilter(e.key) : null,
              ))
          .toList(),
    );
  }
}

class _FilterButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool isSelected;
  final bool compact;
  final VoidCallback? onTap;

  const _FilterButton({
    required this.label,
    required this.color,
    required this.isSelected,
    this.compact = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: onTap == null ? null : (_) => onTap!(),
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      avatar: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: colors.border),
        ),
        child: const SizedBox.square(dimension: SkotiqTokens.iconXs),
      ),
    );
  }
}
