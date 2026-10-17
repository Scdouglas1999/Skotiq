part of '../tutorial_overlay.dart';

class _TutorialOverlayContent extends StatefulWidget {
  final TutorialStep? step;
  final int currentIndex;
  final int totalSteps;
  final bool isFirst;
  final bool isLast;
  final Animation<double> ringAnimation;
  final Animation<double> ringOpacityAnimation;
  final bool isBusy;
  final bool isAdvancing;
  final bool isGoingBack;
  final bool isSkipping;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onSkip;
  final VoidCallback? onSpotlightTapped;

  const _TutorialOverlayContent({
    required this.step,
    required this.currentIndex,
    required this.totalSteps,
    required this.isFirst,
    required this.isLast,
    required this.ringAnimation,
    required this.ringOpacityAnimation,
    required this.isBusy,
    required this.isAdvancing,
    required this.isGoingBack,
    required this.isSkipping,
    required this.onNext,
    required this.onPrevious,
    required this.onSkip,
    this.onSpotlightTapped,
  });

  @override
  State<_TutorialOverlayContent> createState() =>
      _TutorialOverlayContentState();
}

class _TutorialOverlayContentState extends State<_TutorialOverlayContent> {
  final FocusNode _focusNode = FocusNode();
  int _lastAnnouncedIndex = -1;

  @override
  void initState() {
    super.initState();
    // Request focus when the overlay is shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _announceStep();
    });
  }

  @override
  void didUpdateWidget(_TutorialOverlayContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Announce step change to screen readers
    if (oldWidget.currentIndex != widget.currentIndex) {
      _announceStep();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _announceStep() {
    if (widget.step != null && widget.currentIndex != _lastAnnouncedIndex) {
      _lastAnnouncedIndex = widget.currentIndex;
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Step ${widget.currentIndex + 1} of ${widget.totalSteps}: ${widget.step!.title}. ${widget.step!.description}',
        TextDirection.ltr,
      );
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (widget.isBusy) return KeyEventResult.handled;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onSkip();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      widget.onNext();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (!widget.isFirst) {
        widget.onPrevious();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      widget.onNext();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Determine spotlight shape based on target dimensions
  SpotlightShape _getSpotlightShape(Rect? targetRect) {
    if (targetRect == null) return SpotlightShape.roundedRect;

    // Use aspect ratio to guess appropriate shape
    final aspectRatio = targetRect.width / targetRect.height;

    // Square-ish elements (icons, circular buttons) -> circle
    if (aspectRatio > 0.8 && aspectRatio < 1.2) {
      return SpotlightShape.circle;
    }

    // Wide elements (text buttons, labels) -> pill
    if (aspectRatio > 2.0) {
      return SpotlightShape.pill;
    }

    // Default to rounded rect
    return SpotlightShape.roundedRect;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.step == null) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    final targetKey = TutorialKeys.getKey(widget.step!.targetKey);
    Rect? targetRect;

    if (targetKey?.currentContext != null) {
      final renderBox =
          targetKey!.currentContext!.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final position = renderBox.localToGlobal(Offset.zero);
        targetRect = Rect.fromLTWH(
          position.dx,
          position.dy,
          renderBox.size.width,
          renderBox.size.height,
        );
      }
    }

    final spotlightShape = _getSpotlightShape(targetRect);
    final screenSize = MediaQuery.sizeOf(context);

    // Check if step is interactive (allows click-through)
    // Default to interactive when a target is available
    final isInteractive = targetRect != null;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Semantics(
        // This node is focusable — the `Focus` above it takes the keyboard for
        // the whole tour — so it has to declare an enabled state. Without one
        // it dumps as `panel: Tutorial step 1 of 12: … [DISABLED]`: an overlay
        // that says it holds your keyboard and is dead at the same time. It is
        // live (Enter/Space/Backspace/Escape all do something), and it says
        // so.
        container: true,
        enabled: true,
        label:
            'Tutorial step ${widget.currentIndex + 1} of ${widget.totalSteps}: ${widget.step!.title}',
        hint:
            'Press Enter or Space for next step, Backspace for previous, Escape to skip',
        child: Stack(
          children: [
            // Dimmed background with spotlight - uses custom hit testing
            _SpotlightHitTestWidget(
              targetRect: targetRect,
              padding: 8,
              isInteractive: isInteractive,
              onSpotlightTapped: widget.onSpotlightTapped,
              child: CustomPaint(
                size: Size(screenSize.width, screenSize.height),
                painter: _SpotlightPainter(
                  targetRect: targetRect,
                  padding: 8,
                  dimColor: colors.background.withValues(alpha: 0.85),
                  shape: spotlightShape,
                ),
              ),
            ),

            // Expanding ring pulse effect around target
            if (targetRect != null)
              AnimatedBuilder(
                animation: widget.ringAnimation,
                builder: (context, child) {
                  return _ExpandingRingPainter.buildWidget(
                    targetRect: targetRect!,
                    padding: 8,
                    ringProgress: widget.ringAnimation.value,
                    ringOpacity: widget.ringOpacityAnimation.value,
                    ringColor: colors.primary,
                    shape: spotlightShape,
                  );
                },
              ),

            // Tooltip
            _TooltipWidget(
              step: widget.step!,
              targetRect: targetRect,
              currentIndex: widget.currentIndex,
              totalSteps: widget.totalSteps,
              isFirst: widget.isFirst,
              isLast: widget.isLast,
              isBusy: widget.isBusy,
              isAdvancing: widget.isAdvancing,
              isGoingBack: widget.isGoingBack,
              isSkipping: widget.isSkipping,
              onNext: widget.onNext,
              onPrevious: widget.onPrevious,
              onSkip: widget.onSkip,
            ),
          ],
        ),
      ),
    );
  }
}

/// Widget that handles hit testing for the spotlight area
/// Clicks within the spotlight "hole" pass through to underlying widgets
/// Clicks outside the spotlight (on the dim area) are blocked
