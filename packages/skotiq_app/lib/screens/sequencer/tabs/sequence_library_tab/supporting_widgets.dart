part of '../sequence_library_tab.dart';

class _StatChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;

  const _StatChip({
    required this.colors,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.textMuted),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }
}

class _IconButton extends StatefulWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onPressed;

  const _IconButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    this.color,
    required this.onPressed,
  });

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? widget.colors.textSecondary;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _isHovered
                  ? SkotiqDecorations.tintedBadge(
                      color,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline8),
                    ).color
                  : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _isHovered ? color : widget.colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
