import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A filled icon-over-label pill button used for sidebar / panel sub-tabs.
///
/// The one implementation of the pill styling, shared with the imaging panel.
/// It renders a centered [Icon] above a small [label], with an animated
/// selected/hover surface that matches the rest of the Skotiq design
/// system.
///
/// The visual contract:
///  * 180ms `easeOutCubic` animated container
///  * padding `EdgeInsets.symmetric(horizontal: 6, vertical: 8)`
///  * selected => [SkotiqDecorations.selectedSurface] with `fillAlpha: 0.16`
///  * unselected => surface/surfaceHover fill, 8px radius, border/borderHighlight
///  * icon size 16, label fontSize 10 (w600 selected / w500 otherwise)
class PillTab extends StatefulWidget {
  /// Icon shown above the label.
  final IconData icon;

  /// Text label shown below the icon (and used as the tooltip/semantics label).
  final String label;

  /// Whether this pill is the currently-selected tab.
  final bool isSelected;

  /// Invoked when the pill is tapped.
  final VoidCallback onTap;

  /// Optional tooltip override. Defaults to [label] when null.
  final String? tooltip;

  /// Theme colors used for the fill, border, and text.
  final SkotiqColors colors;

  /// Compact density for phones (especially landscape, where vertical space is
  /// tight): smaller icon, label, padding and gap so a grid of these fits
  /// without crowding the short viewport. Defaults to the desktop sizing.
  final bool dense;

  const PillTab({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
    this.tooltip,
    this.dense = false,
  });

  @override
  State<PillTab> createState() => _PillTabState();
}

class _PillTabState extends State<PillTab> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip ?? widget.label,
      child: Semantics(
        // Semantics publishes isEnabled only when this field is given;
        // omitting it makes assistive tech announce a live control as
        // disabled. Measured on the running app 2026-08-09.
        enabled: true,
        button: true,
        selected: widget.isSelected,
        label: widget.label,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: widget.dense
                  ? const EdgeInsets.symmetric(horizontal: 5, vertical: 5)
                  : const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              decoration: widget.isSelected
                  ? SkotiqDecorations.selectedSurface(
                      widget.colors.primary,
                      fillAlpha: 0.16,
                    )
                  : BoxDecoration(
                      color: _isHovered
                          ? widget.colors.surfaceHover
                          : widget.colors.surface,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusLg),
                      border: Border.all(
                        color: _isHovered
                            ? widget.colors.borderHighlight
                            : widget.colors.border,
                      ),
                    ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    widget.icon,
                    size: widget.dense ? 14 : 16,
                    color: widget.isSelected
                        ? widget.colors.primary
                        : widget.colors.textSecondary,
                  ),
                  SizedBox(height: widget.dense ? 2 : 4),
                  Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: widget.dense
                          ? SkotiqTypography.fontSize9
                          : SkotiqTypography.fontSize10,
                      fontWeight:
                          widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: widget.isSelected
                          ? widget.colors.primary
                          : _isHovered
                              ? widget.colors.textPrimary
                              : widget.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
