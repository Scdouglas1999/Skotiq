import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart' show SolvedWcs;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/preview_transform.dart';
import '../catalog_overlay_widget.dart';
import 'image_display.dart';
import 'overlay_painters.dart';
import 'preview_display_scale.dart';

/// A frame drawn in a viewport: fitted, or zoomed and panned, with its stars
/// circled and its catalog objects labeled when asked. The live frame and a
/// saved frame shown at full resolution are both drawn by this.
///
/// [zoomLevel] is relative to fit (1.0 fits the whole frame), as
/// [ImagingViewerState] keeps it.
class FrameCanvas extends StatelessWidget {
  const FrameCanvas({
    super.key,
    required this.image,
    required this.viewport,
    required this.zoomLevel,
    required this.panOffset,
    required this.semanticsLabel,
    this.onPan,
    this.stars,
    this.showCatalog = false,
    this.wcs,
    this.frameSolve,
  });

  final CapturedImageData image;
  final Size viewport;
  final double zoomLevel;
  final Offset panOffset;
  final String semanticsLabel;

  /// Drags pan the frame while it is zoomed.
  final ValueChanged<Offset>? onPan;

  /// The stars to circle; null draws none.
  final List<DetectedStar>? stars;

  final bool showCatalog;

  /// The frame's solution, for the catalog labels.
  final SolvedWcs? wcs;

  /// The frame's background solve, which says why [wcs] is missing.
  final FrameSolveVm? frameSolve;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitScale = previewFitScale(
      viewportSize: viewport,
      imageSize: imageSize,
    );
    final displayScale = fitScale * zoomLevel;
    final imageOffset = computeImageOffset(
      viewportSize: viewport,
      imageSize: imageSize,
      zoomLevel: displayScale,
      panOffset: panOffset,
    );
    final zoomed = zoomLevel != 1.0;
    // Decode only what the viewport can show while fitted; 1:1 needs every
    // pixel.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetWidth =
        zoomed ? null : math.max(1, (viewport.width * dpr).round());
    final stars = this.stars;
    final pan = onPan;

    return Semantics(
      image: true,
      label: semanticsLabel,
      child: GestureDetector(
        onPanUpdate:
            zoomed && pan != null ? (details) => pan(details.delta) : null,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ExcludeSemantics(
              child: ImageDisplayWidget(
                imageData: image,
                zoomLevel: zoomLevel,
                panOffset: panOffset,
                targetWidth: targetWidth,
              ),
            ),
            if (stars != null && stars.isNotEmpty)
              IgnorePointer(
                child: CustomPaint(
                  painter: StarOverlayPainter(
                    stars: stars,
                    color: colors.accent.withValues(alpha: 0.8),
                    zoomLevel: displayScale,
                    imageOffset: imageOffset,
                  ),
                ),
              ),
            if (showCatalog)
              CatalogOverlayWidget(
                wcs: wcs,
                zoomLevel: displayScale,
                imageOffset: imageOffset,
                imageSize: imageSize,
                frameSolve: frameSolve,
              ),
          ],
        ),
      ),
    );
  }
}
