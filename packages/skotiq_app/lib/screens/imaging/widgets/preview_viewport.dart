import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/preview_transform.dart';
import '../../../widgets/red_night_filter.dart';
import 'preview_display_scale.dart';

/// Where a preview's image actually is on screen.
///
/// Every overlay that draws in image coordinates needs the same three numbers,
/// and they have to come from the widget that laid the image out rather than
/// be re-derived per overlay — that is how an overlay ends up describing a
/// picture that is not on screen.
@immutable
class PreviewViewportGeometry {
  const PreviewViewportGeometry({
    required this.viewportSize,
    required this.imageSize,
    required this.fitScale,
    required this.displayScale,
    required this.imageOffset,
  });

  final Size viewportSize;
  final Size imageSize;

  /// Screen pixels per image pixel with the zoom multiplier at 1.0.
  final double fitScale;

  /// Screen pixels per image pixel as drawn. This — not the viewer's
  /// fit-relative zoom multiplier — is what `imageToViewport` wants.
  final double displayScale;

  /// Top-left of the drawn image in viewport coordinates.
  final Offset imageOffset;
}

/// Builds one overlay for a laid-out preview.
typedef PreviewOverlayBuilder = Widget Function(
    BuildContext context, PreviewViewportGeometry geometry);

/// A pan-and-zoom viewport for one already-decoded image, with overlays that
/// are handed the geometry they need.
///
/// Factored out of the live view so a second canvas — the live stack — can put
/// the same rectangle tool over a different picture without a second copy of
/// the letterboxing arithmetic. It deliberately takes a [ui.Image] rather than
/// any of the app's frame models: the live view decodes a captured sub and the
/// stacker decodes a u16 composite, and neither one's model belongs in the
/// other's canvas.
///
/// The painting must stay the shape `previewFitScale` documents — a
/// `CustomPaint` constrained to the viewport, then `BoxFit.contain` inside it —
/// because that formula is what every overlay's geometry is computed from.
class PreviewViewport extends StatelessWidget {
  const PreviewViewport({
    super.key,
    required this.image,
    required this.zoomLevel,
    required this.panOffset,
    this.overlays = const <PreviewOverlayBuilder>[],
    this.onPanUpdate,
    this.onZoomIn,
    this.onZoomOut,
    this.background,
  });

  /// The picture. Decoding and stretching belong to the caller.
  final ui.Image image;

  /// Multiplier on top of fit-to-window, matching `ImagingViewerState`.
  final double zoomLevel;
  final Offset panOffset;

  /// Drawn over the image, in order, each inside a `Positioned.fill`.
  final List<PreviewOverlayBuilder> overlays;

  /// Drag on empty canvas pans the frame. Null disables panning.
  final ValueChanged<Offset>? onPanUpdate;

  /// Scroll wheel over the canvas. Null disables wheel zoom.
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  /// The canvas colour. Defaults to the image-anchored dark ground the live
  /// view uses, with red night keeping its own palette.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final Size imageSize = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewportSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        final double fitScale = previewFitScale(
          viewportSize: viewportSize,
          imageSize: imageSize,
        );
        final double displayScale = fitScale * zoomLevel;
        final Offset imageOffset = computeImageOffset(
          viewportSize: viewportSize,
          imageSize: imageSize,
          zoomLevel: displayScale,
          panOffset: panOffset,
        );
        final geometry = PreviewViewportGeometry(
          viewportSize: viewportSize,
          imageSize: imageSize,
          fitScale: fitScale,
          displayScale: displayScale,
          imageOffset: imageOffset,
        );

        return Listener(
          onPointerSignal: (PointerSignalEvent signal) {
            if (signal is! PointerScrollEvent) return;
            if (signal.scrollDelta.dy > 0) {
              onZoomOut?.call();
            } else if (signal.scrollDelta.dy < 0) {
              onZoomIn?.call();
            }
          },
          child: GestureDetector(
            onPanUpdate: onPanUpdate == null
                ? null
                : (DragUpdateDetails details) => onPanUpdate!(details.delta),
            child: Container(
              // The canvas is a photo backdrop, so it stays on the dark ladder
              // in every theme EXCEPT red night, where the wavelength rule
              // outranks the image-anchoring one.
              color: background ??
                  (colors.isRedNight
                      ? colors.background
                      : SkotiqColors.dark.background),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: RedNightImage(
                      child: ClipRect(
                        child: Center(
                          child: Transform.translate(
                            offset: panOffset,
                            child: Transform.scale(
                              scale: zoomLevel,
                              alignment: Alignment.center,
                              child: CustomPaint(
                                painter: _ViewportImagePainter(image: image),
                                size: imageSize,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  for (final PreviewOverlayBuilder overlay in overlays)
                    Positioned.fill(child: overlay(context, geometry)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ViewportImagePainter extends CustomPainter {
  const _ViewportImagePainter({required this.image});

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(0, 0, size.width, size.height),
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_ViewportImagePainter oldDelegate) =>
      oldDelegate.image != image;
}
