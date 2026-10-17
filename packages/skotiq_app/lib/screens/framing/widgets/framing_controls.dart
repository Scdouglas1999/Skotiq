import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'package:skotiq_app/utils/snackbar_helper.dart';

part 'framing_controls_parts/_rotation_fields.dart';
part 'framing_controls_parts/_fov_controls.dart';
part 'framing_controls_parts/_mosaic_controls.dart';

/// Generic label/slider/value row used for rotation, overlap, and similar
/// scalar controls in the right-hand control panel.
class FramingSliderField extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String? suffix;
  final SkotiqColors colors;
  final ValueChanged<double>? onChanged;

  const FramingSliderField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.suffix,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: colors.primary,
              inactiveTrackColor: colors.border,
              thumbColor: colors.primary,
              overlayColor: colors.primary.withValues(alpha: 0.1),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 45,
          child: Text(
            '${value.toInt()}${suffix ?? ''}',
            style: SkotiqTypography.caption.copyWith(color: colors.textPrimary),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

/// Small toggle pill (rectangle chip with active/inactive states), used for
/// quick on/off toggles in the framing controls (Grid, Labels, Directions).
class FramingToggleChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const FramingToggleChip({
    super.key,
    required this.label,
    required this.isActive,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? colors.primary.withValues(alpha: 0.2) : colors.well,
          borderRadius: SkotiqTokens.borderRadiusMd,
          border: Border.all(
            color: isActive
                ? colors.primary.withValues(alpha: 0.5)
                : colors.border,
          ),
        ),
        child: Text(
          label,
          style: SkotiqTypography.caption.copyWith(
            color: isActive ? colors.primary : colors.textSecondary,
            fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// Compact icon button with tooltip and hover state, used next to the manual
/// RA/Dec entry fields.
class FramingSmallIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const FramingSmallIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onTap,
  });

  @override
  State<FramingSmallIconButton> createState() => _FramingSmallIconButtonState();
}

class _FramingSmallIconButtonState extends State<FramingSmallIconButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isHovered ? widget.colors.primary : widget.colors.well,
              borderRadius: SkotiqTokens.borderRadiusMd,
              border: Border.all(color: widget.colors.border),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _isHovered
                  ? widget.colors.textPrimary
                  : widget.colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
