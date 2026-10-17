import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// Position of the tooltip relative to the target widget
enum SkotiqTooltipPosition { top, bottom, left, right }

/// A styled tooltip with animations and accent shadow.
///
/// Features:
/// - 300ms delay before showing
/// - Fade + scale animation on appear/disappear
/// - Dark background with subtle accent-tinted shadow
/// - Arrow pointer aligned to target
class SkotiqTooltip extends StatefulWidget {
  /// The widget that triggers the tooltip
  final Widget child;

  /// The message to display in the tooltip
  final String message;

  /// Rich content for the tooltip (overrides message)
  final Widget? richMessage;

  /// Position of the tooltip relative to the child
  final SkotiqTooltipPosition position;

  /// Delay before showing the tooltip
  final Duration waitDuration;

  /// Duration of the show/hide animation
  final Duration animationDuration;

  /// Whether to show the arrow pointer
  final bool showArrow;

  /// Maximum width of the tooltip
  final double maxWidth;

  const SkotiqTooltip({
    super.key,
    required this.child,
    required this.message,
    this.richMessage,
    this.position = SkotiqTooltipPosition.top,
    this.waitDuration = const Duration(milliseconds: 300),
    this.animationDuration = SkotiqTokens.durationNormal,
    this.showArrow = true,
    this.maxWidth = 240,
  });

  @override
  State<SkotiqTooltip> createState() => _SkotiqTooltipState();
}

/// The tooltip currently on screen, app-wide.
///
/// One tooltip at a time is the contract, and this single slot is what enforces
/// it: every `SkotiqTooltip` owns an independent `OverlayPortalController`,
/// the touch trigger retires only on its own 3 s timer or a second long-press,
/// and a hover that never gets its matching `onExit` (pointer leaves the
/// window, trigger rebuilt away under the cursor) would strand its label
/// indefinitely.
_SkotiqTooltipState? _visibleTooltip;

class _SkotiqTooltipState extends State<SkotiqTooltip>
    with SingleTickerProviderStateMixin {
  final _overlayController = OverlayPortalController();
  final GlobalKey _childKey = GlobalKey();
  late AnimationController _animController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  bool _isHovered = false;
  Timer? _dismissTimer;
  Timer? _showTimer;

  /// Retires the overlay once the fade-out has run.
  ///
  /// NOT `_animController.reverse().then(...)`: a `TickerFuture` whose ticker
  /// is cancelled — which is what a second `reverse()`, a `forward()` or a
  /// `stop()` does — never completes and never throws, so the callback that
  /// calls `hide()` is silently dropped and the overlay stays mounted with its
  /// opacity at zero: invisible on screen and fully present in the
  /// accessibility tree.
  Timer? _hideTimer;

  /// Retires a hover tooltip that was never told the pointer left.
  ///
  /// `MouseRegion.onExit` does not arrive when the trigger is rebuilt or
  /// removed under the cursor, or when the pointer leaves the window in one
  /// jump. A tooltip is a transient hint, so it retires on its own.
  Timer? _lifetimeTimer;

  static const Duration _maxVisible = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: SkotiqTokens.curveSnappy,
      ),
    );
  }

  /// A rebuild of the trigger retires the label.
  ///
  /// `MouseRegion.onExit` does not fire when the widget under the cursor is
  /// rebuilt with new configuration — the pointer never moved, so there is no
  /// exit to report — and the tooltip then names a control that has changed
  /// out from under it, or is gone. The rail reproduced it every time:
  /// hovering a collapsed item and clicking it rebuilds the whole rail with a
  /// new selection, and the old item's label stayed up over the page body
  /// until the six-second lifetime clock retired it.
  ///
  /// Not gated on the message changing: it is the trigger's identity that is
  /// in question, and a rail item whose label is unchanged is still a
  /// different item once the rail has rebuilt around it.
  ///
  /// A PENDING show is deliberately left alone. Several triggers live under
  /// parents that rebuild on a timer (the planetarium's clocks, the imaging
  /// toolbars), and cancelling the hover delay on every one of those rebuilds
  /// would mean their tooltips never appeared at all.
  @override
  void didUpdateWidget(SkotiqTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_overlayController.isShowing) _retireImmediately();
  }

  /// Leaving the tree takes the overlay with it.
  ///
  /// `deactivate` runs before `dispose` and before the element is reparented,
  /// which is the only hook that fires when a trigger is moved or removed
  /// while the overlay is up. The overlay child is retired by the
  /// `OverlayPortal` going down with this subtree; what this has to do is
  /// release the app-wide visible slot and stop the clocks, so a tooltip that
  /// was mid-hover cannot resurrect itself or block the next one.
  ///
  /// It must NOT call `hide()`: mutating the overlay from inside a
  /// deactivation pass rebuilds an element that is already being taken down,
  /// and Flutter asserts `_dependents.isEmpty` on the focus scope.
  @override
  void deactivate() {
    _dismissTimer?.cancel();
    _showTimer?.cancel();
    _showTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    _isHovered = false;
    if (identical(_visibleTooltip, this)) _visibleTooltip = null;
    super.deactivate();
  }

  /// Takes the label off screen at the end of this frame, with no fade.
  ///
  /// The animated [_hideTooltip] is right for a pointer that left; it is wrong
  /// for a trigger that has been rebuilt, because the 160 ms fade-out is
  /// 160 ms of a label describing something that no longer exists.
  ///
  /// The teardown is deferred one frame because the caller is
  /// [didUpdateWidget], which runs inside the build phase: both
  /// `OverlayPortalController.hide()` and driving the fade controller assert
  /// there — `hide()` on the scheduler phase, the controller because its
  /// listeners would mark an already-building subtree dirty. The state that
  /// decides is torn down synchronously, so a second retirement or a
  /// resurrection cannot race the callback.
  void _retireImmediately() {
    _dismissTimer?.cancel();
    _showTimer?.cancel();
    _showTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    _isHovered = false;
    if (identical(_visibleTooltip, this)) _visibleTooltip = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The pointer coming back re-enters through _showTooltip, which owns
      // the slot again; retiring here would then hide a live tooltip.
      if (!mounted || _isHovered) return;
      _animController.value = 0;
      if (_overlayController.isShowing) _overlayController.hide();
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _lifetimeTimer?.cancel();
    if (identical(_visibleTooltip, this)) _visibleTooltip = null;
    _animController.dispose();
    super.dispose();
  }

  /// Takes the single visible-tooltip slot, retiring whoever held it.
  void _claimVisibility() {
    final previous = _visibleTooltip;
    if (previous != null && !identical(previous, this)) {
      previous._hideTooltip();
    }
    _visibleTooltip = this;
  }

  // The hover delay is a Timer rather than a `Future.delayed` so dispose() can
  // cancel it; an uncancellable delay keeps this state object alive past
  // teardown and turns any throw into an unhandled zone error.
  void _showTooltip() {
    if (_overlayController.isShowing || _showTimer != null) return;

    _isHovered = true;
    _showTimer = Timer(widget.waitDuration, () {
      _showTimer = null;
      if (!_isHovered || !mounted) return;
      _claimVisibility();
      _hideTimer?.cancel();
      _hideTimer = null;
      _overlayController.show();
      _animController.forward();
      _armLifetime();
    });
  }

  /// (Re)start the self-retirement clock for a tooltip that is on screen.
  void _armLifetime() {
    _lifetimeTimer?.cancel();
    _lifetimeTimer = Timer(_maxVisible, () {
      if (mounted && _overlayController.isShowing) _hideTooltip();
    });
  }

  void _hideTooltip() {
    _dismissTimer?.cancel();
    _showTimer?.cancel();
    _showTimer = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    _isHovered = false;
    if (identical(_visibleTooltip, this)) _visibleTooltip = null;
    _animController.reverse();
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.animationDuration, () {
      _hideTimer = null;
      if (mounted && !_isHovered && _overlayController.isShowing) {
        _overlayController.hide();
      }
    });
  }

  // Touch trigger: show immediately on long-press (no hover), toggle off on a
  // repeat long-press, and auto-dismiss after a few seconds.
  void _toggleTooltipForTouch() {
    if (_overlayController.isShowing) {
      _hideTooltip();
      return;
    }
    _dismissTimer?.cancel();
    _showTimer?.cancel();
    _showTimer = null;
    _hideTimer?.cancel();
    _hideTimer = null;
    _isHovered = true;
    _claimVisibility();
    _overlayController.show();
    _animController.forward();
    _armLifetime();
    _dismissTimer = Timer(const Duration(seconds: 3), _hideTooltip);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: (context) {
        // The floating label publishes NO accessible node, ever. A tooltip
        // belongs to its trigger in the accessibility model (below, as
        // `Semantics.tooltip`), and an overlay that outlives its hover by even
        // one frame otherwise leaves a free-floating panel in the tree naming
        // a control that is not on screen — the D-2 defect, which reproduced
        // with three planetarium toolbar labels listed over a clean bar.
        return _TooltipOverlay(
          targetKey: _childKey,
          message: widget.message,
          richMessage: widget.richMessage,
          position: widget.position,
          showArrow: widget.showArrow,
          maxWidth: widget.maxWidth,
          fadeAnimation: _fadeAnimation,
          scaleAnimation: _scaleAnimation,
        );
      },
      child: MouseRegion(
        onEnter: (_) => _showTooltip(),
        // Pointer movement over the trigger is the proof that the hover is
        // still live, so it pushes the self-retirement clock back.
        onHover: (_) {
          if (_overlayController.isShowing) _armLifetime();
        },
        onExit: (_) => _hideTooltip(),
        // A press anywhere retires the label, including a press on the
        // trigger itself. A click on a hovered rail item rebuilds the rail
        // under the cursor, and the label for the item as it WAS is the one
        // thing on screen that has not moved. Listener, not GestureDetector:
        // this must not compete for the gesture the child is claiming.
        child: Listener(
          behavior: HitTestBehavior.deferToChild,
          onPointerUp: (_) {
            if (_overlayController.isShowing) _hideTooltip();
          },
          child: GestureDetector(
            onLongPress: _toggleTooltipForTouch,
            child: Semantics(
              tooltip: widget.message,
              child: KeyedSubtree(key: _childKey, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class _TooltipOverlay extends StatelessWidget {
  final GlobalKey targetKey;
  final String message;
  final Widget? richMessage;
  final SkotiqTooltipPosition position;
  final bool showArrow;
  final double maxWidth;
  final Animation<double> fadeAnimation;
  final Animation<double> scaleAnimation;

  const _TooltipOverlay({
    required this.targetKey,
    required this.message,
    this.richMessage,
    required this.position,
    required this.showArrow,
    required this.maxWidth,
    required this.fadeAnimation,
    required this.scaleAnimation,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    // Get target position from the trigger child's render box (not this
    // overlay's own context, which lives under the Overlay subtree).
    final renderBox =
        targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return const SizedBox.shrink();

    // The overlay child is laid out in the HOST OVERLAY's coordinate space, not
    // the screen's, so the anchor is measured against that same overlay: screen
    // coordinates laid out against an overlay assumed to start at (0, 0)
    // displace the tooltip by exactly the overlay's inset. `MediaQuery.sizeOf`
    // is wrong for the same reason — the edge the tooltip must stay inside is
    // the overlay's, and two clamps that disagree constrain it to one box while
    // positioning it in another.
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final targetSize = renderBox.size;
    final targetPosition = renderBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final screenSize = overlayBox != null && overlayBox.hasSize
        ? overlayBox.size
        : MediaQuery.sizeOf(context);

    // Safety check for valid values
    if (targetSize.width.isNaN ||
        targetSize.height.isNaN ||
        targetPosition.dx.isNaN ||
        targetPosition.dy.isNaN ||
        screenSize.width <= 0 ||
        screenSize.height <= 0) {
      return const SizedBox.shrink();
    }

    // Anchor on the target's facing edge, then let the layout delegate offset
    // by the tooltip's measured size. The arrow is PART of that measured
    // child, so subtracting an extra arrow-length here used to park the label
    // one arrow away from the control it names.
    double left = 0;
    double top = 0;
    const padding = 8.0;

    switch (position) {
      case SkotiqTooltipPosition.top:
        left = targetPosition.dx + (targetSize.width / 2);
        top = targetPosition.dy - padding;
      case SkotiqTooltipPosition.bottom:
        left = targetPosition.dx + (targetSize.width / 2);
        top = targetPosition.dy + targetSize.height + padding;
      case SkotiqTooltipPosition.left:
        left = targetPosition.dx - padding;
        top = targetPosition.dy + (targetSize.height / 2);
      case SkotiqTooltipPosition.right:
        left = targetPosition.dx + targetSize.width + padding;
        top = targetPosition.dy + (targetSize.height / 2);
    }

    // Anchor point only. Turning it into a final on-screen rect needs the
    // tooltip's measured size, which is why that happens in the layout delegate
    // below rather than here.
    //
    // Clamping `left`/`top` here is NOT enough: the tooltip is then offset by a
    // fraction of its own width, so a `right`-positioned one anchored at
    // `screenWidth - 8` still draws its whole width past the edge and a
    // `top`/`bottom` one still draws half of it outside.
    return Positioned.fill(
      // `Positioned` must stay a direct child of the Overlay's Stack, so the
      // semantics exclusion goes here, around the content.
      child: ExcludeSemantics(
        child: CustomSingleChildLayout(
          delegate: _TooltipLayoutDelegate(
            anchor: Offset(left, top),
            position: position,
            padding: padding,
            viewport: screenSize,
          ),
          child: AnimatedBuilder(
            animation: fadeAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: fadeAnimation.value,
                child: Transform.scale(
                  scale: scaleAnimation.value,
                  alignment: _getScaleAlignment(),
                  child: child,
                ),
              );
            },
            child: _buildTooltipContent(
              colors,
              position,
              targetPosition,
              targetSize,
            ),
          ),
        ),
      ),
    );
  }

  Alignment _getScaleAlignment() {
    switch (position) {
      case SkotiqTooltipPosition.top:
        return Alignment.bottomCenter;
      case SkotiqTooltipPosition.bottom:
        return Alignment.topCenter;
      case SkotiqTooltipPosition.left:
        return Alignment.centerRight;
      case SkotiqTooltipPosition.right:
        return Alignment.centerLeft;
    }
  }

  Widget _buildTooltipContent(
    SkotiqColors colors,
    SkotiqTooltipPosition pos,
    Offset targetPos,
    Size targetSize,
  ) {
    Widget content = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: SkotiqDecorations.popover(colors),
      child:
          richMessage ??
          Text(
            message,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textPrimary,
            ),
          ),
    );

    if (!showArrow) return content;

    final arrow = _buildArrow(colors, pos);
    return switch (pos) {
      SkotiqTooltipPosition.top => Column(
        mainAxisSize: MainAxisSize.min,
        children: [content, arrow],
      ),
      SkotiqTooltipPosition.bottom => Column(
        mainAxisSize: MainAxisSize.min,
        children: [arrow, content],
      ),
      SkotiqTooltipPosition.left => Row(
        mainAxisSize: MainAxisSize.min,
        children: [content, arrow],
      ),
      SkotiqTooltipPosition.right => Row(
        mainAxisSize: MainAxisSize.min,
        children: [arrow, content],
      ),
    };
  }

  Widget _buildArrow(SkotiqColors colors, SkotiqTooltipPosition pos) {
    // Vertical painter; left/right rotate it so the tip still faces the
    // control. Size stays 16×8 so the rotation produces an 8×16 pointer.
    final painted = CustomPaint(
      size: const Size(16, 8),
      painter: _ArrowPainter(
        color: colors.surfaceElevated,
        borderColor: colors.border,
        isPointingUp: pos == SkotiqTooltipPosition.bottom,
      ),
    );
    return switch (pos) {
      SkotiqTooltipPosition.top ||
      SkotiqTooltipPosition.bottom => painted,
      SkotiqTooltipPosition.left => RotatedBox(
        quarterTurns: 3,
        child: painted,
      ),
      SkotiqTooltipPosition.right => RotatedBox(
        quarterTurns: 1,
        child: painted,
      ),
    };
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  final Color borderColor;
  final bool isPointingUp;

  _ArrowPainter({
    required this.color,
    required this.borderColor,
    required this.isPointingUp,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final path = Path();
    if (isPointingUp) {
      path.moveTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width / 2, size.height);
    }
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) {
    return color != oldDelegate.color ||
        borderColor != oldDelegate.borderColor ||
        isPointingUp != oldDelegate.isPointingUp;
  }
}

/// Places the tooltip relative to its anchor and keeps it fully on screen.
///
/// A layout delegate rather than arithmetic at build time because the decision
/// needs the tooltip's MEASURED size: the offset from the anchor is half (or all)
/// of the tooltip's own width/height depending on which side it sits, and only
/// the layout pass knows that. Clamping the anchor instead leaves the box itself
/// hanging off the edge — see the note at the call site.
class _TooltipLayoutDelegate extends SingleChildLayoutDelegate {
  const _TooltipLayoutDelegate({
    required this.anchor,
    required this.position,
    required this.padding,
    required this.viewport,
  });

  /// The point on the trigger the tooltip points at.
  final Offset anchor;
  final SkotiqTooltipPosition position;

  /// Minimum gap kept between the tooltip and each viewport edge.
  final double padding;
  final Size viewport;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // Never ask the tooltip to be wider or taller than the space it has to fit
    // in, so a long message wraps instead of being clipped.
    final maxWidth = (viewport.width - padding * 2).clamp(0.0, double.infinity);
    final maxHeight = (viewport.height - padding * 2).clamp(
      0.0,
      double.infinity,
    );
    return constraints.loosen().copyWith(
      maxWidth: maxWidth == 0 ? constraints.maxWidth : maxWidth,
      maxHeight: maxHeight == 0 ? constraints.maxHeight : maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Offset the anchor by the tooltip's own extent for the chosen side, which
    // is what centres it on the trigger (or sits it fully to one side).
    double x;
    double y;
    switch (position) {
      case SkotiqTooltipPosition.top:
        x = anchor.dx - childSize.width / 2;
        y = anchor.dy - childSize.height;
      case SkotiqTooltipPosition.bottom:
        x = anchor.dx - childSize.width / 2;
        y = anchor.dy;
      case SkotiqTooltipPosition.left:
        x = anchor.dx - childSize.width;
        y = anchor.dy - childSize.height / 2;
      case SkotiqTooltipPosition.right:
        x = anchor.dx;
        y = anchor.dy - childSize.height / 2;
    }

    // Now clamp the REAL box. Upper bounds are lower-bounded by `padding` so a
    // tooltip larger than the viewport still starts on screen and is clipped at
    // the far edge, rather than being pushed off the near one.
    final maxX = (size.width - childSize.width - padding).clamp(
      padding,
      double.infinity,
    );
    final maxY = (size.height - childSize.height - padding).clamp(
      padding,
      double.infinity,
    );
    return Offset(x.clamp(padding, maxX), y.clamp(padding, maxY));
  }

  @override
  bool shouldRelayout(_TooltipLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      position != oldDelegate.position ||
      padding != oldDelegate.padding ||
      viewport != oldDelegate.viewport;
}
