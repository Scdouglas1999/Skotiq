import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Screen pixels per image pixel in the live preview.
///
/// The viewer state's `zoomLevel` is NOT this number: it is a multiplier
/// *relative to fit-to-window* (see `ImagingViewerState.zoomLevel`, "1.0 =
/// fit-to-window"). Consumers that need real geometry — the zoom readout, and
/// every overlay painter that maps image coordinates onto the canvas — must use
/// the scale the frame is actually drawn at, or they describe a picture that is
/// not on screen. Published by `LivePreviewArea`, which is the only widget that
/// knows the preview viewport.
///
/// Defaults to 1.0 so a reader that runs before the preview has laid out (or
/// with no frame loaded) sees "unscaled" rather than zero.
final previewDisplayScaleProvider = StateProvider<double>((ref) => 1.0);

/// Screen pixels per image pixel the current frame would be drawn at with the
/// zoom multiplier at 1.0 — i.e. the fit-to-window scale.
///
/// The zoom mutators need this to translate an *absolute* intent ("1:1", "no
/// more than 800% of actual") into the fit-relative multiplier the viewer state
/// stores: without it `zoom1to1` cannot know how far from 1:1 fit is. Published
/// by `LivePreviewArea` alongside [previewDisplayScaleProvider]; 1.0 until the
/// preview has laid out a frame, which makes fit and 1:1 agree — correct, since
/// with no frame there is nothing to magnify.
final previewFitScaleProvider = StateProvider<double>((ref) => 1.0);

/// Scale at which [imageSize] is rendered inside [viewportSize] at fit.
///
/// Mirrors what `ImageDisplayWidget` actually does: its `CustomPaint` is sized
/// `constraints.constrain(imageSize)` — so at most the viewport — and then
/// `paintImage(fit: BoxFit.contain)` letterboxes the frame inside that box.
/// The `1.0` term is the "constrain" half: a frame smaller than the viewport is
/// drawn at native size, never blown up to fill it.
double previewFitScale({
  required Size viewportSize,
  required Size imageSize,
}) {
  if (imageSize.width <= 0 || imageSize.height <= 0) return 1.0;
  if (viewportSize.width <= 0 || viewportSize.height <= 0) return 1.0;
  return math.min(
    1.0,
    math.min(
      viewportSize.width / imageSize.width,
      viewportSize.height / imageSize.height,
    ),
  );
}
