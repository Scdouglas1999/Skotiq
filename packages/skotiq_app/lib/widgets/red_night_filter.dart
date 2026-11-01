// The red-night filter for IMAGE DATA.
//
// Red night puts every chrome pixel on the pure red channel by palette. Image
// data cannot get there that way: a radar map, an astro frame, a thumbnail and
// a Darkroom preview all arrive as arbitrary RGB. So image data is filtered:
// its luminance is re-emitted on the red channel alone, which keeps every
// structure the operator needs to read (cloud bands, star fields, gradients)
// while emitting no green or blue.

import 'package:flutter/widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Wraps [child] in the red-axis filter when the red-night theme is active,
/// and returns it untouched in every other theme.
///
/// Use this at EVERY site that paints pixels Skotiq did not choose: the
/// weather radar/satellite map, the Imaging frame and live stack, frame
/// thumbnails, the Darkroom preview. Chrome must NOT use it — chrome is already
/// on the red axis by palette, and filtering it a second time would crush the
/// contrast the palette was tuned for.
class RedNightImage extends StatelessWidget {
  const RedNightImage({super.key, required this.child});

  final Widget child;

  /// Rec. 709 luma coefficients — the same weighting the contrast checks use,
  /// so a filtered pixel keeps the lightness it had.
  static const double _lumaR = 0.2126;
  static const double _lumaG = 0.7152;
  static const double _lumaB = 0.0722;

  /// How much luminance is re-emitted as red. Full strength: red is the only
  /// channel the theme spends.
  static const double _redGain = 1.0;

  /// The 5x4 matrix Flutter applies as `C' = m·[R,G,B,A,1]`. The green and
  /// blue rows are zero, so every filtered pixel has G == B == 0.
  static const ColorFilter filter = ColorFilter.matrix(<double>[
    _lumaR * _redGain, _lumaG * _redGain, _lumaB * _redGain, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    if (!SkotiqColors.of(context).isRedNight) return child;
    return ColorFiltered(colorFilter: filter, child: child);
  }
}
