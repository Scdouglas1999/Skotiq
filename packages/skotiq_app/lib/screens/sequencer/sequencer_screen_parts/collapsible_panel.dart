part of '../sequencer_screen.dart';

class _CollapsiblePanel extends StatefulWidget {
  final SkotiqColors colors;
  final bool isCollapsed;
  final double collapsedWidth;
  final double expandedWidth;
  final double minExpandedWidth;
  final double maxExpandedWidth;
  final ResizeSide side;
  final IconData collapsedIcon;
  final String collapsedTooltip;
  final VoidCallback onToggle;

  /// Called with the new width when the user drags the panel edge. The parent
  /// persists this so the drag survives the next layout pass.
  final ValueChanged<double>? onWidthChanged;
  final Widget child;

  const _CollapsiblePanel({
    required this.colors,
    required this.isCollapsed,
    required this.collapsedWidth,
    required this.expandedWidth,
    required this.minExpandedWidth,
    required this.maxExpandedWidth,
    required this.side,
    required this.collapsedIcon,
    required this.collapsedTooltip,
    required this.onToggle,
    this.onWidthChanged,
    required this.child,
  });

  @override
  State<_CollapsiblePanel> createState() => _CollapsiblePanelState();
}

class _CollapsiblePanelState extends State<_CollapsiblePanel>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _widthAnimation;
  double _currentExpandedWidth = 0;

  @override
  void initState() {
    super.initState();
    _currentExpandedWidth = widget.expandedWidth;
    _animationController = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationSmooth,
    );
    _updateAnimation();
    if (!widget.isCollapsed) {
      _animationController.value = 1.0;
    }
  }

  void _updateAnimation() {
    _widthAnimation = Tween<double>(
      begin: widget.collapsedWidth,
      end: _currentExpandedWidth,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: SkotiqTokens.curveStandard,
    ));
  }

  @override
  void didUpdateWidget(_CollapsiblePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCollapsed != widget.isCollapsed) {
      // Only re-seed the expanded width on a collapse→expand transition,
      // so reopening the panel respects the latest (possibly user-dragged)
      // width handed down by the parent.
      if (widget.isCollapsed) {
        _animationController.reverse();
      } else {
        _currentExpandedWidth = widget.expandedWidth;
        _updateAnimation();
        _animationController.forward();
      }
    } else if (oldWidget.expandedWidth != widget.expandedWidth &&
        !widget.isCollapsed) {
      // Width changed while already expanded (responsive resize, or a
      // persisted drag flowing back in). Snap to the new width instantly by
      // jumping the controller to its end value instead of re-tweening — a
      // re-tween mid-resize makes the edge visibly lag the cursor.
      _currentExpandedWidth = widget.expandedWidth;
      _updateAnimation();
      if (_animationController.value != 1.0) {
        _animationController.value = 1.0;
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The panel slides at the token pace, and not at all when the platform has
    // asked for no motion — the width still changes, it just arrives on the
    // frame the toggle was pressed.
    _animationController.duration =
        animationDuration(context, SkotiqTokens.durationSmooth);
    return AnimatedBuilder(
      animation: _widthAnimation,
      builder: (context, child) {
        final width = _widthAnimation.value;
        final isEffectivelyCollapsed = width < widget.collapsedWidth + 20;

        if (isEffectivelyCollapsed) {
          // Collapsed state - show icon button strip
          return Container(
            width: widget.collapsedWidth,
            decoration: BoxDecoration(
              color: widget.colors.surface,
              border: Border(
                left: widget.side == ResizeSide.left
                    ? BorderSide(color: widget.colors.border)
                    : BorderSide.none,
                right: widget.side == ResizeSide.right
                    ? BorderSide(color: widget.colors.border)
                    : BorderSide.none,
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: SkotiqTokens.spaceSm),
                SkotiqIconButton(
                  icon: widget.collapsedIcon,
                  tooltip: widget.collapsedTooltip,
                  onPressed: widget.onToggle,
                ),
              ],
            ),
          );
        }

        // Expanded state - show resizable panel with content
        return SizedBox(
          width: width,
          child: ResizablePanel(
            initialWidth: width,
            minWidth: widget.minExpandedWidth,
            maxWidth: widget.maxExpandedWidth,
            side: widget.side,
            onWidthChanged: (newWidth) {
              setState(() {
                _currentExpandedWidth = newWidth;
                _updateAnimation();
              });
              // Bubble the dragged width up so the parent can persist it;
              // otherwise it snaps back on the next rebuild.
              widget.onWidthChanged?.call(newWidth);
            },
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// Layout for very narrow desktop/tablet screens.
///
/// Below the minimum-width threshold we keep a thin
/// draggable icon-only rail on the left so users can still drag nodes
/// onto the tree. A "More..." button at the bottom of the rail opens the
/// full node palette sheet for search/discovery. The properties FAB is
/// preserved for editing the selected node.
