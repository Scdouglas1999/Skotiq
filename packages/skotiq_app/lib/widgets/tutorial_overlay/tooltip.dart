part of '../tutorial_overlay.dart';

class _TooltipWidget extends StatelessWidget {
  final TutorialStep step;
  final Rect? targetRect;
  final int currentIndex;
  final int totalSteps;
  final bool isFirst;
  final bool isLast;
  final bool isBusy;
  final bool isAdvancing;
  final bool isGoingBack;
  final bool isSkipping;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onSkip;

  const _TooltipWidget({
    required this.step,
    this.targetRect,
    required this.currentIndex,
    required this.totalSteps,
    required this.isFirst,
    required this.isLast,
    required this.isBusy,
    required this.isAdvancing,
    required this.isGoingBack,
    required this.isSkipping,
    required this.onNext,
    required this.onPrevious,
    required this.onSkip,
  });

  /// Get responsive tooltip width based on screen size
  double _getTooltipWidth(double screenWidth) {
    if (screenWidth < 600) return screenWidth * 0.85; // Mobile
    if (screenWidth < 1200) return 360; // Tablet
    return 400; // Desktop
  }

  /// Get responsive title font size
  double _getTitleSize(double screenWidth) {
    return screenWidth < 600 ? 14 : 16;
  }

  /// Get responsive description font size
  double _getDescriptionSize(double screenWidth) {
    return screenWidth < 600 ? 12 : 13;
  }

  /// Get responsive padding
  double _getPadding(double screenWidth) {
    return screenWidth < 600 ? 16 : 20;
  }

  /// Calculate the best position for the tooltip to avoid overflow
  ({double? left, double? top, double? right, double? bottom})
      _calculateBestPosition(
    Rect? targetRect,
    Size screenSize,
    double tooltipWidth,
  ) {
    const tooltipPadding = 16.0;
    const estimatedTooltipHeight = 200.0;
    final screenWidth = screenSize.width;

    // No target - use position hint or default placement
    if (targetRect == null) {
      if (step.position == TooltipPosition.center) {
        // Place in bottom-right corner so users can see main content
        // On mobile, center it instead
        if (screenWidth < 600) {
          return (
            left: (screenWidth - tooltipWidth) / 2,
            top: null,
            right: null,
            bottom: tooltipPadding + 24,
          );
        }
        return (
          left: null,
          top: null,
          right: tooltipPadding + 24,
          bottom: tooltipPadding + 24,
        );
      }
      // Center the tooltip
      return (
        left: (screenWidth - tooltipWidth) / 2,
        top: screenSize.height / 2 - 100,
        right: null,
        bottom: null,
      );
    }

    // Has target but wants center - center below target
    if (step.position == TooltipPosition.center) {
      return (
        left: (screenWidth - tooltipWidth) / 2,
        top: math.max(
            targetRect.bottom + tooltipPadding, screenSize.height / 2 - 100),
        right: null,
        bottom: null,
      );
    }

    // Try preferred position first
    var preferredPosition = step.position;
    var result = _tryPosition(
      preferredPosition,
      targetRect,
      screenSize,
      tooltipWidth,
      estimatedTooltipHeight,
      tooltipPadding,
    );

    if (_isValidPosition(result, screenSize, tooltipWidth,
        estimatedTooltipHeight, tooltipPadding)) {
      return result;
    }

    // Try opposite position
    final oppositePosition = _getOppositePosition(preferredPosition);
    result = _tryPosition(
      oppositePosition,
      targetRect,
      screenSize,
      tooltipWidth,
      estimatedTooltipHeight,
      tooltipPadding,
    );

    if (_isValidPosition(result, screenSize, tooltipWidth,
        estimatedTooltipHeight, tooltipPadding)) {
      return result;
    }

    // Try perpendicular positions
    final perpendicularPositions =
        _getPerpendicularPositions(preferredPosition);
    for (final position in perpendicularPositions) {
      result = _tryPosition(
        position,
        targetRect,
        screenSize,
        tooltipWidth,
        estimatedTooltipHeight,
        tooltipPadding,
      );

      if (_isValidPosition(result, screenSize, tooltipWidth,
          estimatedTooltipHeight, tooltipPadding)) {
        return result;
      }
    }

    // Last resort: center on screen
    return (
      left: (screenWidth - tooltipWidth) / 2,
      top: (screenSize.height - estimatedTooltipHeight) / 2,
      right: null,
      bottom: null,
    );
  }

  /// Try to position the tooltip at a specific position
  ({double? left, double? top, double? right, double? bottom}) _tryPosition(
    TooltipPosition position,
    Rect targetRect,
    Size screenSize,
    double tooltipWidth,
    double tooltipHeight,
    double padding,
  ) {
    switch (position) {
      case TooltipPosition.right:
        return (
          left: targetRect.right + padding,
          top: targetRect.top,
          right: null,
          bottom: null,
        );
      case TooltipPosition.left:
        return (
          left: null,
          top: targetRect.top,
          right: screenSize.width - targetRect.left + padding,
          bottom: null,
        );
      case TooltipPosition.bottom:
        return (
          left: targetRect.left,
          top: targetRect.bottom + padding,
          right: null,
          bottom: null,
        );
      case TooltipPosition.top:
        return (
          left: targetRect.left,
          top: null,
          right: null,
          bottom: screenSize.height - targetRect.top + padding,
        );
      case TooltipPosition.center:
        return (
          left: (screenSize.width - tooltipWidth) / 2,
          top: targetRect.bottom + padding,
          right: null,
          bottom: null,
        );
    }
  }

  /// Check if a position would result in the tooltip being visible on screen
  bool _isValidPosition(
    ({double? left, double? top, double? right, double? bottom}) position,
    Size screenSize,
    double tooltipWidth,
    double tooltipHeight,
    double padding,
  ) {
    double left = position.left ?? 0;
    double top = position.top ?? 0;

    // Calculate actual left if right is specified
    if (position.right != null) {
      left = screenSize.width - position.right! - tooltipWidth;
    }

    // Calculate actual top if bottom is specified
    if (position.bottom != null) {
      top = screenSize.height - position.bottom! - tooltipHeight;
    }

    // Check bounds
    return left >= padding &&
        left + tooltipWidth <= screenSize.width - padding &&
        top >= padding &&
        top + tooltipHeight <= screenSize.height - padding;
  }

  /// Get the opposite position
  TooltipPosition _getOppositePosition(TooltipPosition position) {
    switch (position) {
      case TooltipPosition.top:
        return TooltipPosition.bottom;
      case TooltipPosition.bottom:
        return TooltipPosition.top;
      case TooltipPosition.left:
        return TooltipPosition.right;
      case TooltipPosition.right:
        return TooltipPosition.left;
      case TooltipPosition.center:
        return TooltipPosition.center;
    }
  }

  /// Get perpendicular positions
  List<TooltipPosition> _getPerpendicularPositions(TooltipPosition position) {
    switch (position) {
      case TooltipPosition.top:
      case TooltipPosition.bottom:
        return [TooltipPosition.right, TooltipPosition.left];
      case TooltipPosition.left:
      case TooltipPosition.right:
        return [TooltipPosition.bottom, TooltipPosition.top];
      case TooltipPosition.center:
        return [
          TooltipPosition.bottom,
          TooltipPosition.right,
          TooltipPosition.top,
          TooltipPosition.left
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;

    // Responsive sizing
    final tooltipWidth = _getTooltipWidth(screenWidth);
    final titleSize = _getTitleSize(screenWidth);
    final descriptionSize = _getDescriptionSize(screenWidth);
    final padding = _getPadding(screenWidth);
    const tooltipPadding = 16.0;

    // Calculate smart tooltip position
    final position =
        _calculateBestPosition(targetRect, screenSize, tooltipWidth);

    // Apply clamping to ensure tooltip stays on screen
    double? finalLeft = position.left;
    double? finalTop = position.top;

    if (finalLeft != null) {
      finalLeft = math.max(
        tooltipPadding,
        math.min(finalLeft, screenWidth - tooltipWidth - tooltipPadding),
      );
    }
    if (finalTop != null) {
      finalTop = math.max(
        tooltipPadding,
        math.min(finalTop, screenSize.height - 200),
      );
    }

    return Positioned(
      left: finalLeft,
      top: finalTop,
      right: position.right,
      bottom: position.bottom,
      child: Semantics(
        container: true,
        label: 'Tutorial: ${step.title}',
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: tooltipWidth,
            padding: EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
              boxShadow: [
                BoxShadow(
                  color: colors.background.withValues(alpha: 0.5),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Semantics(
                  header: true,
                  child: Text(
                    step.title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: titleSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // Description
                Text(
                  step.description,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: descriptionSize,
                    height: 1.4,
                  ),
                ),

                const SizedBox(height: 16),

                // Progress indicator - use a progress bar instead of dots for many steps
                Semantics(
                  label: 'Progress: step ${currentIndex + 1} of $totalSteps',
                  child: Row(
                    children: [
                      // Progress bar
                      Expanded(
                        child: ClipRRect(
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusXs),
                          child: LinearProgressIndicator(
                            value: totalSteps > 1
                                ? (currentIndex + 1) / totalSteps
                                : 1,
                            backgroundColor: colors.border,
                            valueColor: AlwaysStoppedAnimation(colors.primary),
                            minHeight: 4,
                          ),
                        ),
                      ),

                      const SizedBox(width: 12),

                      Text(
                        '${currentIndex + 1} / $totalSteps',
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: SkotiqTypography.fontSize11,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Navigation buttons
                Row(
                  children: [
                    // Skip button
                    Semantics(
                      button: true,
                      // Live 2026-08-09: `button: true` without `enabled` publishes no
                      // isEnabled flag, and AT-SPI reads that as disabled — the same
                      // false signal the sequencer tabs carried.
                      enabled: true,
                      label: 'Skip tour',
                      hint: 'Press Escape to skip',
                      child: SkotiqButton(
                        onPressed: isBusy ? null : onSkip,
                        label: 'Skip tour',
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                        isLoading: isSkipping,
                      ),
                    ),

                    const Spacer(),

                    // Previous button
                    if (!isFirst)
                      Semantics(
                        button: true,
                        // Live 2026-08-09: `button: true` without `enabled` publishes no
                        // isEnabled flag, and AT-SPI reads that as disabled — the same
                        // false signal the sequencer tabs carried.
                        enabled: true,
                        label: 'Previous step',
                        hint: 'Press Backspace or Left Arrow',
                        child: SkotiqButton(
                          onPressed: isBusy ? null : onPrevious,
                          label: 'Back',
                          icon: LucideIcons.chevronLeft,
                          variant: ButtonVariant.ghost,
                          size: ButtonSize.small,
                          isLoading: isGoingBack,
                        ),
                      ),

                    const SizedBox(width: 8),

                    // Next/Done button
                    Semantics(
                      button: true,
                      // Live 2026-08-09: `button: true` without `enabled` publishes no
                      // isEnabled flag, and AT-SPI reads that as disabled — the same
                      // false signal the sequencer tabs carried.
                      enabled: true,
                      label: isLast ? 'Finish tutorial' : 'Next step',
                      hint: 'Press Enter, Space, or Right Arrow',
                      child: SkotiqButton(
                        onPressed: isBusy ? null : onNext,
                        label: isLast ? 'Done' : 'Next',
                        icon: isLast ? null : LucideIcons.chevronRight,
                        size: ButtonSize.small,
                        isLoading: isAdvancing,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
