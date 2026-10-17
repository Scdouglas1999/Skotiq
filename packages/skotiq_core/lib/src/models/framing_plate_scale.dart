import 'dart:ui' show Size, Rect, Offset;

/// Single source of truth for the framing canvas's astrometric scale.
///
/// The survey-image painter, the FOV/reticle overlay and the gesture
/// hit-testing math must all use the same angular-to-pixel mapping, or a
/// reticle stops corresponding to the pixels the survey background occupies
/// under it. This immutable value object is that mapping.
///
/// It is constructed from the *known astrometry of the loaded survey image*
/// (its angular field of view, in degrees, and its pixel dimensions) and then
/// answers two questions that every framing painter and gesture handler must
/// agree on:
///
///  * [pixelsPerDegree] — how many on-screen logical pixels span one degree of
///    sky, given the current canvas size and zoom.
///  * [drawRectFor] — the exact destination rectangle the survey background is
///    drawn into, given canvas size, zoom and pan. Painters and gesture math
///    share this *one* geometry so overlays line up with the imagery to the
///    pixel.
///
/// The fit-to-canvas logic here is intentionally identical to
/// `FramingSurveyImagePainter.paint` (see
/// `packages/skotiq_app/lib/screens/framing/painters/framing_background_painters.dart`):
/// the larger-aspect dimension is pinned to the canvas extent (scaled by zoom)
/// and the other dimension follows from the image aspect ratio. Any change to
/// the painter's draw math must be mirrored here, and vice versa — they are two
/// views of the same geometry and this class is the canonical one.
///
/// Pure Dart: depends only on `dart:ui`'s [Size]/[Rect]/[Offset] geometry
/// primitives, never on Flutter widgets, so it is fully unit-testable and can be
/// shared across providers, painters and gesture handlers.
class FramingPlateScale {
  /// Angular width of the loaded survey image, in degrees of sky.
  ///
  /// This is the field of view the survey cutout was requested at; the full
  /// pixel width of the image ([imagePixelWidth]) maps onto exactly this many
  /// degrees of sky along the horizontal axis.
  final double surveyFovWidthDeg;

  /// Angular height of the loaded survey image, in degrees of sky.
  final double surveyFovHeightDeg;

  /// Native pixel width of the decoded survey image.
  final int imagePixelWidth;

  /// Native pixel height of the decoded survey image.
  final int imagePixelHeight;

  const FramingPlateScale({
    required this.surveyFovWidthDeg,
    required this.surveyFovHeightDeg,
    required this.imagePixelWidth,
    required this.imagePixelHeight,
  });

  /// The image's pixel aspect ratio (width / height).
  double get imageAspect => imagePixelWidth / imagePixelHeight;

  /// Computes the fit-to-canvas drawn width of the survey image, in logical
  /// pixels, for the given [canvasSize] and [zoom].
  ///
  /// This is the shared primitive behind both [pixelsPerDegree] and
  /// [drawRectFor]. It mirrors `FramingSurveyImagePainter` exactly: when the
  /// image is wider (relative to its height) than the canvas, the width is
  /// pinned to the canvas width times [zoom]; otherwise the height is pinned to
  /// the canvas height times [zoom] and the width follows the aspect ratio.
  ///
  /// The returned [Size] is the on-screen extent the image is rendered at; its
  /// aspect ratio always equals [imageAspect].
  Size drawSizeFor(Size canvasSize, double zoom) {
    final canvasAspect = canvasSize.width / canvasSize.height;
    final aspect = imageAspect;

    double drawWidth;
    double drawHeight;
    if (aspect > canvasAspect) {
      drawWidth = canvasSize.width * zoom;
      drawHeight = drawWidth / aspect;
    } else {
      drawHeight = canvasSize.height * zoom;
      drawWidth = drawHeight * aspect;
    }
    return Size(drawWidth, drawHeight);
  }

  /// On-screen logical pixels per degree of sky for the given [canvasSize] and
  /// [zoom].
  ///
  /// Because the survey image's full pixel width corresponds to
  /// [surveyFovWidthDeg] degrees of sky, and the image is drawn fit-to-canvas
  /// at a width of `drawSizeFor(...).width`, the on-screen scale is simply that
  /// drawn width divided by the angular width. The result is independent of
  /// whether the image is letterboxed horizontally or vertically against the
  /// canvas — the angular-to-pixel mapping is isotropic because both the width
  /// and height fits preserve [imageAspect], and the survey cutout's pixel
  /// aspect matches its FOV aspect.
  double pixelsPerDegree(Size canvasSize, double zoom) {
    return drawSizeFor(canvasSize, zoom).width / surveyFovWidthDeg;
  }

  /// The destination rectangle the survey background is drawn into, for the
  /// given [canvasSize], [zoom] and [pan].
  ///
  /// The image is centered on the canvas and then displaced by [pan]. This is
  /// the single geometry source every painter and gesture handler must use:
  /// the survey painter draws into this rect, FOV/reticle overlays project sky
  /// coordinates through [pixelsPerDegree] relative to this rect's center, and
  /// gesture hit-testing inverts it. Sharing one rect guarantees overlays and
  /// imagery stay pixel-aligned under any pan/zoom.
  Rect drawRectFor(Size canvasSize, double zoom, Offset pan) {
    final drawSize = drawSizeFor(canvasSize, zoom);
    final center = Offset(
      canvasSize.width / 2 + pan.dx,
      canvasSize.height / 2 + pan.dy,
    );
    return Rect.fromCenter(
      center: center,
      width: drawSize.width,
      height: drawSize.height,
    );
  }

  FramingPlateScale copyWith({
    double? surveyFovWidthDeg,
    double? surveyFovHeightDeg,
    int? imagePixelWidth,
    int? imagePixelHeight,
  }) {
    return FramingPlateScale(
      surveyFovWidthDeg: surveyFovWidthDeg ?? this.surveyFovWidthDeg,
      surveyFovHeightDeg: surveyFovHeightDeg ?? this.surveyFovHeightDeg,
      imagePixelWidth: imagePixelWidth ?? this.imagePixelWidth,
      imagePixelHeight: imagePixelHeight ?? this.imagePixelHeight,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FramingPlateScale &&
        other.surveyFovWidthDeg == surveyFovWidthDeg &&
        other.surveyFovHeightDeg == surveyFovHeightDeg &&
        other.imagePixelWidth == imagePixelWidth &&
        other.imagePixelHeight == imagePixelHeight;
  }

  @override
  int get hashCode => Object.hash(
    surveyFovWidthDeg,
    surveyFovHeightDeg,
    imagePixelWidth,
    imagePixelHeight,
  );

  @override
  String toString() =>
      'FramingPlateScale('
      'surveyFovWidthDeg: $surveyFovWidthDeg, '
      'surveyFovHeightDeg: $surveyFovHeightDeg, '
      'imagePixelWidth: $imagePixelWidth, '
      'imagePixelHeight: $imagePixelHeight)';
}
