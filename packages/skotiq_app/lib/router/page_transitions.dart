import 'package:flutter/material.dart';

/// Collection of beautiful, professional page transition builders
class PageTransitions {
  PageTransitions._();

  /// Smooth slide and fade transition - professional and efficient
  static Widget slideFadeTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child, {
    Offset beginOffset = const Offset(0.0, 0.02),
    double beginOpacity = 0.0,
  }) {
    const curve = Curves.easeOutCubic;
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: curve,
    );

    return SlideTransition(
      position: Tween<Offset>(
        begin: beginOffset,
        end: Offset.zero,
      ).animate(curvedAnimation),
      child: FadeTransition(
        opacity: Tween<double>(
          begin: beginOpacity,
          end: 1.0,
        ).animate(curvedAnimation),
        child: child,
      ),
    );
  }

  /// Horizontal slide transition - great for tab-like navigation
  static Widget horizontalSlideTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child, {
    bool slideFromRight = true,
  }) {
    const curve = Curves.easeInOutCubic;
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: curve,
    );

    final offset =
        slideFromRight ? const Offset(1.0, 0.0) : const Offset(-1.0, 0.0);

    return SlideTransition(
      position: Tween<Offset>(
        begin: offset,
        end: Offset.zero,
      ).animate(curvedAnimation),
      child: FadeTransition(
        opacity: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(curvedAnimation),
        child: child,
      ),
    );
  }

  /// Scale and fade transition - elegant for modals and overlays
  static Widget scaleFadeTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child, {
    double beginScale = 0.95,
  }) {
    const curve = Curves.easeOutCubic;
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: curve,
    );

    return ScaleTransition(
      scale: Tween<double>(
        begin: beginScale,
        end: 1.0,
      ).animate(curvedAnimation),
      child: FadeTransition(
        opacity: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(curvedAnimation),
        child: child,
      ),
    );
  }

  /// Subtle vertical slide - perfect for content appearing
  static Widget verticalSlideTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child, {
    bool slideFromBottom = true,
  }) {
    const curve = Curves.easeOutCubic;
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: curve,
    );

    final offset =
        slideFromBottom ? const Offset(0.0, 0.03) : const Offset(0.0, -0.03);

    return SlideTransition(
      position: Tween<Offset>(
        begin: offset,
        end: Offset.zero,
      ).animate(curvedAnimation),
      child: FadeTransition(
        opacity: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(curvedAnimation),
        child: child,
      ),
    );
  }

  /// No transition - instant (useful for certain cases)
  static Widget noTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}
