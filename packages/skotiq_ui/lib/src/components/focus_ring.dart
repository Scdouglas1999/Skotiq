import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';

/// A wrapper that adds a crisp focus ring for keyboard navigation.
class FocusRing extends StatefulWidget {
  /// The child widget to wrap
  final Widget child;

  /// Focus node to track (optional, creates one if not provided)
  final FocusNode? focusNode;

  /// Border radius for the focus ring
  final BorderRadius? borderRadius;

  /// Color for the focus ring (defaults to primary)
  final Color? focusColor;

  /// Whether to show the ring only on keyboard focus
  final bool keyboardOnly;

  /// Padding between the child and the focus ring
  final double ringPadding;

  /// Blur radius reserved for API compatibility (ring uses border only).
  final double glowRadius;
  const FocusRing({
    super.key,
    required this.child,
    this.focusNode,
    this.borderRadius,
    this.focusColor,
    this.keyboardOnly = true,
    this.ringPadding = 2.0,
    this.glowRadius = 4.0,
  });

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing>
    with SingleTickerProviderStateMixin {
  late FocusNode _focusNode;

  /// True while [_focusNode] is the node this state created, and so the node
  /// this state must dispose. Reading `widget.focusNode == null` instead is
  /// wrong on a swap: it describes the incoming node, not the outgoing one.
  late bool _ownsNode;
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _ownsNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);

    _controller = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationFast,
    );
    _opacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_handleFocusChange);
      final replaced = _ownsNode ? _focusNode : null;
      _ownsNode = widget.focusNode == null;
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_handleFocusChange);
      // A live FocusNode stays registered with FocusManager, so an abandoned
      // self-created node is a retained listener, not just memory.
      replaced?.dispose();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (_ownsNode) {
      _focusNode.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final hasFocus = _focusNode.hasFocus;

    // Check if focus is from keyboard (not mouse/touch)
    if (widget.keyboardOnly) {
      final focusHighlightMode = FocusManager.instance.highlightMode;
      final isKeyboardFocus =
          focusHighlightMode == FocusHighlightMode.traditional;

      if (hasFocus && isKeyboardFocus) {
        setState(() => _isFocused = true);
        _controller.forward();
      } else {
        _controller.reverse().then((_) {
          if (mounted) setState(() => _isFocused = false);
        });
      }
    } else {
      if (hasFocus) {
        setState(() => _isFocused = true);
        _controller.forward();
      } else {
        _controller.reverse().then((_) {
          if (mounted) setState(() => _isFocused = false);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final effectiveFocusColor = widget.focusColor ?? colors.primary;
    final effectiveRadius = widget.borderRadius ?? SkotiqTokens.borderRadiusMd;

    return Focus(
      focusNode: _focusNode,
      child: AnimatedBuilder(
        animation: _opacityAnimation,
        builder: (context, child) {
          return Container(
            padding: EdgeInsets.all(widget.ringPadding),
            decoration: _isFocused || _opacityAnimation.value > 0
                ? BoxDecoration(
                    borderRadius: effectiveRadius,
                    border: Border.all(
                      color: effectiveFocusColor.withValues(
                        alpha: _opacityAnimation.value * 0.75,
                      ),
                      width: 2,
                    ),
                  )
                : null,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
