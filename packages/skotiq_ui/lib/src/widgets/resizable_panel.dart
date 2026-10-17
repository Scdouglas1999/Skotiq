import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';

enum ResizeSide { left, right }

class ResizablePanel extends StatefulWidget {
  final Widget child;
  final double initialWidth;
  final double minWidth;
  final double maxWidth;
  final ResizeSide side;
  final Color? handleColor;
  final Color? handleHoverColor;
  final void Function(double width)? onWidthChanged;

  const ResizablePanel({
    super.key,
    required this.child,
    this.initialWidth = 300,
    this.minWidth = 200,
    this.maxWidth = 600,
    this.side = ResizeSide.right,
    this.handleColor,
    this.handleHoverColor,
    this.onWidthChanged,
  });

  @override
  State<ResizablePanel> createState() => _ResizablePanelState();
}

class _ResizablePanelState extends State<ResizablePanel> {
  late double _width;
  bool _isHovering = false;
  bool _isResizing = false;

  @override
  void initState() {
    super.initState();
    _width = widget.initialWidth;
  }

  @override
  void didUpdateWidget(ResizablePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isResizing && oldWidget.initialWidth != widget.initialWidth) {
      _width = widget.initialWidth.clamp(widget.minWidth, widget.maxWidth);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final idleHandleColor =
        widget.handleColor ?? colors.border.withValues(alpha: 0.35);
    final activeHandleColor = widget.handleHoverColor ?? colors.borderHighlight;

    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onHorizontalDragStart: (_) => setState(() => _isResizing = true),
        onHorizontalDragEnd: (_) => setState(() => _isResizing = false),
        onHorizontalDragUpdate: (details) {
          setState(() {
            if (widget.side == ResizeSide.right) {
              _width += details.delta.dx;
            } else {
              _width -= details.delta.dx;
            }
            _width = _width.clamp(widget.minWidth, widget.maxWidth);
            widget.onWidthChanged?.call(_width);
          });
        },
        child: Container(
          width: 10,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 2,
              height: double.infinity,
              color: _isResizing || _isHovering
                  ? activeHandleColor
                  : idleHandleColor,
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      width: _width,
      child: Row(
        children: [
          if (widget.side == ResizeSide.right) Expanded(child: widget.child),
          if (widget.side == ResizeSide.right) handle,
          if (widget.side == ResizeSide.left) handle,
          if (widget.side == ResizeSide.left) Expanded(child: widget.child),
        ],
      ),
    );
  }
}
