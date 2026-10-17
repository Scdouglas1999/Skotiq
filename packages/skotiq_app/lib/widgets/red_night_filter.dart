// The red-night filter for IMAGE DATA.
//
// Red night exists to protect a dark-adapted eye, which is why 02 and 03 put
// every chrome pixel on the red axis (G == B). Chrome gets there by using the
// red-night palette. Image data cannot: a radar map, an astro frame, a
// thumbnail and a Darkroom preview all arrive as arbitrary RGB, and a
// full-screen magenta-and-green cloud overlay defeats the theme however
// honestly it encodes rainfall.
//
// So image data is filtered rather than recoloured: luminance is preserved and
// re-emitted on the red axis, which keeps every structure the operator needs to
// read (cloud bands, star fields, gradients) while emitting no green or blue
// the eye has to re-adapt from.

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

  /// How much is re-emitted as green AND blue. Identical for both, so `G == B`
  /// holds by construction rather than by rounding luck.
  ///
  /// Not zero: a pure single-channel image loses the tonal separation that
  /// makes cloud structure readable, and the red-night palette itself is not
  /// pure red (its brightest ink is `#FFB3B3`). 0.18 keeps the structure while
  /// staying far below the level that would re-adapt the eye.
  static const double _greyGain = 0.18;

  /// The 5x4 matrix Flutter applies as `C' = m·[R,G,B,A,1]`.
  ///
  /// Rows 2 and 3 are byte-identical, which is what guarantees the red-axis
  /// invariant: the same inputs through the same coefficients quantise to the
  /// same value, so `|G - B| == 0` for every pixel, not merely a small number.
  static const ColorFilter filter = ColorFilter.matrix(<double>[
    _lumaR * _redGain, _lumaG * _redGain, _lumaB * _redGain, 0, 0, //
    _lumaR * _greyGain, _lumaG * _greyGain, _lumaB * _greyGain, 0, 0, //
    _lumaR * _greyGain, _lumaG * _greyGain, _lumaB * _greyGain, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    if (!SkotiqColors.of(context).isRedNight) return child;
    return ColorFiltered(colorFilter: filter, child: child);
  }
}
