import 'package:flutter/material.dart';

/// Utility for creating staggered animations for lists of widgets
class StaggeredAnimation extends StatelessWidget {
  final int index;
  final int totalItems;
  final Widget child;
  final Duration baseDuration;
  final Duration delayPerItem;
  final Curve curve;
  final bool fadeIn;
  final bool slideIn;
  final Offset slideOffset;

  const StaggeredAnimation({
    super.key,
    required this.index,
    required this.totalItems,
    required this.child,
    this.baseDuration = const Duration(milliseconds: 300),
    this.delayPerItem = const Duration(milliseconds: 50),
    this.curve = Curves.easeOutCubic,
    this.fadeIn = true,
    this.slideIn = true,
    this.slideOffset = const Offset(0.0, 0.02),
  });

  @override
  Widget build(BuildContext context) {
    final delay = delayPerItem * index;
    final duration = baseDuration + (delayPerItem * (totalItems - index));

    return TweenAnimationBuilder<double>(
      duration: duration,
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Interval(
        delay.inMilliseconds / duration.inMilliseconds,
        1.0,
        curve: curve,
      ),
      builder: (context, value, child) {
        Widget result = this.child;

        if (fadeIn) {
          result = Opacity(
            opacity: value,
            child: result,
          );
        }

        if (slideIn) {
          result = Transform.translate(
            offset: Offset(
              slideOffset.dx * (1 - value),
              slideOffset.dy * (1 - value),
            ),
            child: result,
          );
        }

        return result;
      },
    );
  }
}

/// Wrapper widget for animating a list of children with staggered timing
class StaggeredList extends StatelessWidget {
  final List<Widget> children;
  final Duration baseDuration;
  final Duration delayPerItem;
  final Curve curve;
  final bool fadeIn;
  final bool slideIn;
  final Offset slideOffset;
  final Axis direction;

  const StaggeredList({
    super.key,
    required this.children,
    this.baseDuration = const Duration(milliseconds: 300),
    this.delayPerItem = const Duration(milliseconds: 50),
    this.curve = Curves.easeOutCubic,
    this.fadeIn = true,
    this.slideIn = true,
    this.slideOffset = const Offset(0.0, 0.02),
    this.direction = Axis.vertical,
  });

  @override
  Widget build(BuildContext context) {
    return direction == Axis.vertical
        ? Column(
            children: _buildAnimatedChildren(),
          )
        : Row(
            children: _buildAnimatedChildren(),
          );
  }

  List<Widget> _buildAnimatedChildren() {
    return children.asMap().entries.map((entry) {
      return StaggeredAnimation(
        index: entry.key,
        totalItems: children.length,
        baseDuration: baseDuration,
        delayPerItem: delayPerItem,
        curve: curve,
        fadeIn: fadeIn,
        slideIn: slideIn,
        slideOffset: slideOffset,
        child: entry.value,
      );
    }).toList();
  }
}
