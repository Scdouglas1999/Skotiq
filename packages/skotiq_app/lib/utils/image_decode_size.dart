import 'package:flutter/widgets.dart';

/// Decode width, in device pixels, for an image that will be painted into a
/// [logicalWidth]-wide box. Null when the box has no bounded width, which is
/// the one case where there is nothing to derive a size from.
///
/// Flutter decodes an image at its full encoded resolution unless told
/// otherwise, and parks that decode in `PaintingBinding.instance.imageCache`.
/// A 512 px frame thumbnail painted into a 72 px cell is therefore 1 MB of
/// RGBA for 20 KB worth of visible pixels; a full-frame master preview PNG in
/// the same cell is 65 MB. Either way a strip or grid of them walks straight
/// through the cache's byte budget, evicting and re-decoding forever. Asking
/// the decoder for the size actually displayed costs nothing and cuts the
/// footprint by the square of the ratio.
///
/// Use this only where the displayed box is small and bounded. Surfaces where
/// the operator is inspecting pixels — the Imaging canvas, the fullscreen and
/// blink viewers, the Darkroom and master-preview surfaces — must keep their
/// full decode.
int? thumbnailDecodeWidth(BuildContext context, double logicalWidth) {
  if (!logicalWidth.isFinite || logicalWidth <= 0) return null;
  return (logicalWidth * MediaQuery.devicePixelRatioOf(context)).ceil();
}
