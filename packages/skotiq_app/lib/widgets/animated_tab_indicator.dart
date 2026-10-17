import 'package:flutter/material.dart';

/// A custom animated tab indicator with smooth transitions
class AnimatedTabIndicator extends Decoration {
  final Color color;
  final double height;
  final double radius;
  final EdgeInsetsGeometry insets;

  const AnimatedTabIndicator({
    required this.color,
    this.height = 3.0,
    this.radius = 4.0,
    this.insets = EdgeInsets.zero,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _AnimatedTabIndicatorPainter(
      color: color,
      height: height,
      radius: radius,
      insets: insets,
      onChanged: onChanged,
    );
  }

  AnimatedTabIndicator copyWith({
    Color? color,
    double? height,
    double? radius,
    EdgeInsetsGeometry? insets,
  }) {
    return AnimatedTabIndicator(
      color: color ?? this.color,
      height: height ?? this.height,
      radius: radius ?? this.radius,
      insets: insets ?? this.insets,
    );
  }
}

class _AnimatedTabIndicatorPainter extends BoxPainter {
  final Color color;
  final double height;
  final double radius;
  final EdgeInsetsGeometry insets;

  _AnimatedTabIndicatorPainter({
    required this.color,
    required this.height,
    required this.radius,
    required this.insets,
    VoidCallback? onChanged,
  }) : super(onChanged);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final Rect rect = offset & configuration.size!;
    final Rect indicatorRect =
        insets.resolve(configuration.textDirection!).deflateRect(rect);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        indicatorRect.left,
        indicatorRect.bottom - height,
        indicatorRect.width,
        height,
      ),
      Radius.circular(radius),
    );

    canvas.drawRRect(rrect, paint);
  }
}
