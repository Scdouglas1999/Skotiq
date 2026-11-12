part of '../tour_overlay.dart';

/// One step of a coach-mark tour: the dim, the cutout around the target, the
/// pulse ring and the card.
class _CoachMarks extends StatefulWidget {
  const _CoachMarks({
    super.key,
    required this.shown,
    required this.total,
    required this.pulse,
    required this.pendingMove,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  final ValueListenable<_ShownStep?> shown;
  final int total;
  final Animation<double> pulse;
  final _Move? pendingMove;
  final VoidCallback onNext;
  final VoidCallback onBack;
  final VoidCallback onSkip;

  @override
  State<_CoachMarks> createState() => _CoachMarksState();
}

class _CoachMarksState extends State<_CoachMarks> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'tour');
  TourStep? _announced;

  @override
  void initState() {
    super.initState();
    widget.shown.addListener(_announce);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _announce();
    });
  }

  @override
  void didUpdateWidget(_CoachMarks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shown != widget.shown) {
      oldWidget.shown.removeListener(_announce);
      widget.shown.addListener(_announce);
    }
  }

  @override
  void dispose() {
    widget.shown.removeListener(_announce);
    _focusNode.dispose();
    super.dispose();
  }

  void _announce() {
    final shown = widget.shown.value;
    if (shown == null || shown.step == _announced || !mounted) return;
    _announced = shown.step;
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Step ${shown.index + 1} of ${widget.total}: ${shown.step.title}. '
      '${shown.step.description}',
      TextDirection.ltr,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (widget.pendingMove != null) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onSkip();
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowRight) {
      widget.onNext();
    } else if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.arrowLeft) {
      if ((widget.shown.value?.index ?? 0) > 0) widget.onBack();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// A circle for an icon button, a pill for a wide button or a tab, and a
  /// rounded rectangle for anything larger: a circle or a pill around a panel
  /// cuts its corners off.
  static _SpotlightShape _shapeFor(Rect target) {
    if (target.longestSide > 72) {
      return target.height <= 48 && target.width > 2 * target.height
          ? _SpotlightShape.pill
          : _SpotlightShape.roundedRect;
    }
    final aspect = target.width / target.height;
    if (aspect > 0.8 && aspect < 1.2) return _SpotlightShape.circle;
    if (aspect > 2.0) return _SpotlightShape.pill;
    return _SpotlightShape.roundedRect;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ValueListenableBuilder<_ShownStep?>(
        valueListenable: widget.shown,
        builder: (context, shown, _) {
          if (shown == null) return const SizedBox.shrink();
          final step = shown.step;
          final target = shown.spot;
          final shape = target == null ? null : _shapeFor(target);
          return Semantics(
            // Focusable, so it has to declare an enabled state: without one
            // assistive tech reads the panel that holds the keyboard as
            // disabled.
            container: true,
            enabled: true,
            label: 'Tutorial step ${shown.index + 1} of ${widget.total}: '
                '${step.title}',
            hint: 'Press Enter or Space for next step, Backspace for '
                'previous, Escape to skip',
            child: Stack(
              children: [
                Positioned.fill(
                  child: _SpotlightScrim(
                    target: target,
                    child: CustomPaint(
                      painter: _SpotlightPainter(
                        targetRect: target,
                        padding: _spotlightPadding,
                        dimColor: colors.background.withValues(alpha: 0.85),
                        shape: shape ?? _SpotlightShape.roundedRect,
                      ),
                    ),
                  ),
                ),
                if (target != null)
                  AnimatedBuilder(
                    animation: widget.pulse,
                    builder: (context, _) => _ExpandingRingPainter.buildWidget(
                      targetRect: target,
                      padding: _spotlightPadding,
                      ringProgress:
                          Curves.easeOut.transform(widget.pulse.value),
                      ringOpacity: 0.8 *
                          (1 - Curves.easeIn.transform(widget.pulse.value)),
                      ringColor: colors.primary,
                      shape: shape!,
                    ),
                  ),
                Positioned.fill(
                  child: CustomSingleChildLayout(
                    delegate: _CardLayout(
                      target: target?.inflate(_spotlightPadding),
                      side: step.side,
                    ),
                    child: _TourCard(
                      step: step,
                      index: shown.index,
                      total: widget.total,
                      pendingMove: widget.pendingMove,
                      onNext: widget.onNext,
                      onBack: widget.onBack,
                      onSkip: widget.onSkip,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
