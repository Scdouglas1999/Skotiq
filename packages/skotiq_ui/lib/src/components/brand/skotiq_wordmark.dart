import 'package:flutter/material.dart';

import '../../theme/skotiq_colors.dart';
import 'skotiq_mark.dart';
import 'trails_geometry.dart';

/// The Skotiq wordmark — "skotiq", lowercase, Sora SemiBold with −0.04em
/// tracking. Sora is bundled in this package (`assets/fonts/Sora-VF.ttf`),
/// so the wordmark renders offline like the rest of the type system.
class SkotiqWordmark extends StatelessWidget {
  const SkotiqWordmark({super.key, this.fontSize = 20, this.color});

  /// The font family as declared in `skotiq_ui`'s pubspec. A variable font;
  /// [FontWeight.w600] maps onto its `wght` axis.
  static const String fontFamily = 'Sora';

  /// Tracking for the wordmark: −0.04em, the value the approved lockup
  /// specifies. Flutter's [TextStyle.letterSpacing] is in logical pixels,
  /// so callers see it already multiplied by [fontSize].
  static const double trackingEm = -0.04;

  /// Text size in logical pixels. For lockup proportions use
  /// [SkotiqLockup], which derives this from the mark size.
  final double fontSize;

  /// Ink color; inherits the ambient [DefaultTextStyle] when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      'skotiq',
      style: TextStyle(
        fontFamily: fontFamily,
        fontWeight: FontWeight.w600,
        fontSize: fontSize,
        letterSpacing: trackingEm * fontSize,
        color: color,
        height: 1.1,
      ),
    );
  }
}

/// Mark plus wordmark at the approved lockup proportions: the mark is about
/// 1.1× the wordmark's cap height, with a gap of about 0.2× the mark size.
///
/// Sora's cap height is 0.73em, so a wordmark at 1.25× the mark size puts
/// the mark at ~1.1× cap height (`1.25 × 0.73 ≈ 0.91`, i.e. mark/cap ≈ 1.1).
class SkotiqLockup extends StatelessWidget {
  const SkotiqLockup({
    super.key,
    this.markSize = 32,
    this.tone = SkotiqMarkTone.theme,
    this.color,
    this.themeAccent,
    this.motion = SkotiqMarkMotion.none,
    this.tile = false,
    this.onDrawComplete,
  });

  /// Mark side in logical pixels; wordmark size and the gap derive from it.
  final double markSize;

  /// The mark's colorway — the default [SkotiqMarkTone.theme] follows the
  /// active accent; [SkotiqMarkTone.theme] and [SkotiqMarkTone.violet] both
  /// map to red under the red night theme.
  final SkotiqMarkTone tone;

  /// One color for mark lanes and wordmark ink; both inherit their ambient
  /// defaults when null.
  final Color? color;

  /// Forwarded to the mark's [SkotiqMark.themeAccent].
  final Color? themeAccent;

  /// The mark's motion — [SkotiqMarkMotion.draw] for a splash lockup.
  final SkotiqMarkMotion motion;

  /// Whether the mark draws on its rounded tile.
  final bool tile;

  /// Forwarded to the mark's [SkotiqMark.onDrawComplete].
  final VoidCallback? onDrawComplete;

  /// Wordmark size for a given mark size: `fontSize ≈ markSize × 1.25`.
  static double fontSizeFor(double markSize) => markSize * 1.25;

  /// Gap between mark and wordmark: `0.2 × markSize`.
  static double gapFor(double markSize) => markSize * 0.2;

  @override
  Widget build(BuildContext context) {
    final fontSize = fontSizeFor(markSize);
    // The wordmark's ink follows the theme's primary text color so the
    // lockup reads as type; the mark keeps its own colorway.
    final ink = color ?? context.skotiqColors.textPrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SkotiqMark(
          size: markSize,
          tone: tone,
          color: tone == SkotiqMarkTone.mono ? ink : color,
          themeAccent: themeAccent,
          motion: motion,
          tile: tile,
          onDrawComplete: onDrawComplete,
        ),
        SizedBox(width: gapFor(markSize)),
        SkotiqWordmark(fontSize: fontSize, color: ink),
      ],
    );
  }
}
