part of '../tour_overlay.dart';

/// Places a step's card beside its target, from the card's real size.
///
/// The preferred side is tried first, then the opposite one, then the other
/// two; the first where the whole card fits on screen without covering the
/// target wins. With nowhere to fit, or no target, the card goes to the corner
/// of the window that covers the target least. It never leaves the window.
class _CardLayout extends SingleChildLayoutDelegate {
  const _CardLayout({required this.target, required this.side});

  final Rect? target;
  final TourCardSide side;

  static const double _margin = 16;
  static const double _gap = 8;

  /// Below this width the window is a phone and the card spans it.
  static const double _phoneWidth = 600;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final available = constraints.maxWidth - 2 * _margin;
    final width = constraints.maxWidth < _phoneWidth
        ? available
        : math.min(constraints.maxWidth < 1200 ? 360.0 : 400.0, available);
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(0, constraints.maxHeight - 2 * _margin),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = Rect.fromLTRB(
      _margin,
      _margin,
      math.max(_margin, size.width - _margin - childSize.width),
      math.max(_margin, size.height - _margin - childSize.height),
    );
    Offset clamp(Offset offset) => Offset(
          offset.dx.clamp(bounds.left, bounds.right),
          offset.dy.clamp(bounds.top, bounds.bottom),
        );

    final target = this.target;
    if (target != null) {
      for (final candidate in _sidesInOrder) {
        final wanted = switch (candidate) {
          TourCardSide.right => Offset(target.right + _gap, target.top),
          TourCardSide.left =>
            Offset(target.left - _gap - childSize.width, target.top),
          TourCardSide.bottom => Offset(target.left, target.bottom + _gap),
          TourCardSide.top =>
            Offset(target.left, target.top - _gap - childSize.height),
        };
        final placed = clamp(wanted);
        if (!(placed & childSize).overlaps(target)) return placed;
      }
    }

    final corners = [
      if (size.width < _phoneWidth) ...[
        Offset(bounds.left, bounds.bottom),
        Offset(bounds.left, bounds.top),
      ] else ...[
        Offset(bounds.right, bounds.bottom),
        Offset(bounds.left, bounds.bottom),
        Offset(bounds.right, bounds.top),
        Offset(bounds.left, bounds.top),
      ],
    ];
    if (target == null) return corners.first;
    double covered(Offset corner) {
      final overlap = (corner & childSize).intersect(target);
      return overlap.isEmpty ? 0 : overlap.width * overlap.height;
    }

    return corners.reduce((a, b) => covered(b) < covered(a) ? b : a);
  }

  List<TourCardSide> get _sidesInOrder => switch (side) {
        TourCardSide.top => const [
            TourCardSide.top,
            TourCardSide.bottom,
            TourCardSide.right,
            TourCardSide.left,
          ],
        TourCardSide.bottom => const [
            TourCardSide.bottom,
            TourCardSide.top,
            TourCardSide.right,
            TourCardSide.left,
          ],
        TourCardSide.left => const [
            TourCardSide.left,
            TourCardSide.right,
            TourCardSide.bottom,
            TourCardSide.top,
          ],
        TourCardSide.right => const [
            TourCardSide.right,
            TourCardSide.left,
            TourCardSide.bottom,
            TourCardSide.top,
          ],
      };

  @override
  bool shouldRelayout(_CardLayout oldDelegate) =>
      target != oldDelegate.target || side != oldDelegate.side;
}

/// A coach-mark step's card: title, text, progress and the three moves.
class _TourCard extends StatelessWidget {
  const _TourCard({
    required this.step,
    required this.index,
    required this.total,
    required this.pendingMove,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  final TourStep step;
  final int index;
  final int total;
  final _Move? pendingMove;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final phone = MediaQuery.sizeOf(context).width < _CardLayout._phoneWidth;
    final busy = pendingMove != null;
    final isLast = index >= total - 1;

    return Semantics(
      container: true,
      label: 'Tutorial: ${step.title}',
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: EdgeInsets.all(phone ? 16 : 20),
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
              Semantics(
                header: true,
                child: Text(
                  step.title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: phone
                        ? SkotiqTypography.fontSize14
                        : SkotiqTypography.fontSize16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // The text gives way before the buttons do: on a short window
              // it scrolls and Next, Back and Skip stay on screen.
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    step.description,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: phone
                          ? SkotiqTypography.fontSize12
                          : SkotiqTypography.fontSize13,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                label: 'Progress: step ${index + 1} of $total',
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusXs),
                        child: LinearProgressIndicator(
                          value: (index + 1) / total,
                          backgroundColor: colors.border,
                          valueColor: AlwaysStoppedAnimation(colors.primary),
                          minHeight: 4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${index + 1} / $total',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: SkotiqTypography.fontSize11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // On a narrow phone the three buttons do not fit one row; the
              // moves then sit under Skip instead of running off the card.
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                overflowSpacing: 8,
                children: [
                  // `button: true` without `enabled` publishes no enabled
                  // flag, which AT-SPI reads as disabled.
                  Semantics(
                    button: true,
                    enabled: true,
                    label: 'Skip tour',
                    hint: 'Press Escape to skip',
                    child: SkotiqButton(
                      onPressed: busy ? null : onSkip,
                      label: 'Skip tour',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      isLoading: pendingMove == _Move.skip,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (index > 0)
                        Semantics(
                          button: true,
                          enabled: true,
                          label: 'Previous step',
                          hint: 'Press Backspace or Left Arrow',
                          child: SkotiqButton(
                            onPressed: busy ? null : onBack,
                            label: 'Back',
                            icon: LucideIcons.chevronLeft,
                            variant: ButtonVariant.ghost,
                            size: ButtonSize.small,
                            isLoading: pendingMove == _Move.back,
                          ),
                        ),
                      const SizedBox(width: 8),
                      Semantics(
                        button: true,
                        enabled: true,
                        label: isLast ? 'Finish tutorial' : 'Next step',
                        hint: 'Press Enter, Space, or Right Arrow',
                        child: SkotiqButton(
                          onPressed: busy ? null : onNext,
                          label: isLast ? 'Done' : 'Next',
                          icon: isLast ? null : LucideIcons.chevronRight,
                          size: ButtonSize.small,
                          isLoading: pendingMove == _Move.next,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
