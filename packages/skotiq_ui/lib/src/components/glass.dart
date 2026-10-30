import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_theme.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';

/// A translucent blurred panel used ONLY over imagery.
///
/// The image surface stays dark while controls retain the selected accent.
/// Red-night mode preserves its wavelength-restricted palette.
///
/// At most four glass elements on one canvas. The corners are spoken for:
/// top-left frame stats, top-right last-frame status, bottom-left secondary,
/// bottom-right histogram, bottom-centre the capture bar.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.padding = defaultPadding});

  /// The HUD content — a [ReadoutRow], a histogram, a status line, the capture
  /// bar.
  final Widget child;

  /// Internal padding.
  final EdgeInsets padding;

  /// The default HUD padding (`observatory.css` glass blocks: `8 12`).
  static const EdgeInsets defaultPadding = EdgeInsets.symmetric(
    horizontal: SkotiqTokens.spaceMd,
    vertical: SkotiqTokens.spaceSm,
  );

  /// Blur sigma behind the glass (03 §5.2).
  static const double blurSigma = 12;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    // The RepaintBoundary is OUTSIDE everything that could gate an animation.
    // A boundary placed INSIDE an animation gate silently stops the animation
    // and reads as a free performance win; the order here is the fix, not an
    // accident (see memory: animation-gate-repaint-boundary-order).
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: SkotiqTokens.borderRadiusLg,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: padding,
            decoration: SkotiqDecorations.glass(colors),
            child: SkotiqImageSurface(child: child),
          ),
        ),
      ),
    );
  }
}
