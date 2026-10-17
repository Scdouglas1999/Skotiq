import 'package:flutter/widgets.dart';

/// CustomPainter that fills the screen with a dim scrim and punches a
/// rounded-rect hole around [targetRect].
///
/// Why a separate painter instead of reusing TutorialOverlay's: that one
/// owns extra concerns (multiple cutout shapes, hit-testing through the
/// hole, pulse ring) that the onboarding tour doesn't need. The
/// onboarding overlay is always a rounded rect, never click-through (we
/// want every step to advance via explicit Next), and has no pulse —
/// keeping the painter narrow here lets the file stay small enough to
/// audit at a glance.
class OnboardingCutoutPainter extends CustomPainter {
  /// Target rect in the same coordinate space as the painter (i.e. global
  /// screen coordinates if the painter fills the screen). Null means no
  /// cutout — the entire screen is dimmed (used by welcome/completion
  /// steps).
  final Rect? targetRect;

  /// Extra padding inflated around [targetRect] so the spotlight doesn't
  /// touch the target's edges.
  final double padding;

  /// Corner radius of the cutout in logical pixels.
  final double cornerRadius;

  /// Color of the dimming scrim. Caller passes alpha already baked in.
  final Color dimColor;

  /// Color of the highlight border drawn around the cutout. Drawn at
  /// alpha 1.0 — already mid-saturation, so a thin stroke reads as the
  /// "focus ring" without dominating the page.
  final Color borderColor;

  const OnboardingCutoutPainter({
    required this.targetRect,
    required this.padding,
    required this.cornerRadius,
    required this.dimColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dimPaint = Paint()..color = dimColor;
    final fullRect = Offset.zero & size;

    if (targetRect == null) {
      canvas.drawRect(fullRect, dimPaint);
      return;
    }

    final cutout = targetRect!.inflate(padding);
    final rrect = RRect.fromRectAndRadius(
      cutout,
      Radius.circular(cornerRadius),
    );

    // Even-odd fill carves the cutout out of the full-screen rect in a
    // single draw call; cheaper and crisper than drawing four rects
    // around the hole.
    final path = Path()
      ..addRect(fullRect)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, dimPaint);

    // Thin highlight border. Painting it after the cutout means it sits
    // on the surrounding scrim rather than inside the visible widget.
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant OnboardingCutoutPainter oldDelegate) {
    return oldDelegate.targetRect != targetRect ||
        oldDelegate.padding != padding ||
        oldDelegate.cornerRadius != cornerRadius ||
        oldDelegate.dimColor != dimColor ||
        oldDelegate.borderColor != borderColor;
  }
}
