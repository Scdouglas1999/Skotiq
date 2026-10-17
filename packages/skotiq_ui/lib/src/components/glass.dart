import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';

/// A translucent blurred panel used ONLY over imagery.
///
/// **Glass is anchored to the image, not to the theme.** An astro frame is
/// dark in every mode, so the fill, the edge and the TEXT AND CONTROL COLOURS
/// inside glass all come from the dark palette — [child] is built under a
/// `SkotiqColors.dark` override for exactly that reason. A white glass
/// over a black frame was tried and rejected: the fields inside it went
/// grey-on-grey (`mockups/png/imaging-light.png`, before the fix).
///
/// Red night is the one exception, and it outranks the anchoring rule: the
/// wavelength constraint applies to every pixel on the screen including the
/// ones over a photograph, so red night keeps its own palette.
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
    // Red night keeps its own palette; every other theme borrows the dark one,
    // because what is behind the glass is a photograph of the night sky.
    final inner = colors.isRedNight ? colors : SkotiqColors.dark;

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
            // The override reaches the CONTENTS, not just the box: everything
            // inside resolves `SkotiqColors.of(context)` to the dark
            // ladder, so a field or a readout in a light-theme HUD is legible
            // against the frame rather than against a surface that is not
            // there.
            child: Theme(
              data: Theme.of(
                context,
              ).copyWith(extensions: <ThemeExtension<dynamic>>[inner]),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
