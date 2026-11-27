import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/frame_viewer_route.dart';
import '../../../widgets/image_preview/image_display.dart';

/// Fullscreen, pinch-to-zoom inspect view of a captured frame.
///
/// Pushed when the operator taps the live preview on a phone, where the in-place
/// preview otherwise shares the short cover-screen height with the controls
/// panel. System back, Escape, or the close button exits; [InteractiveViewer]
/// gives pinch-zoom + pan so a frame can actually be inspected on a small
/// screen.
class FullscreenImageViewer extends StatelessWidget {
  final CapturedImageData image;

  const FullscreenImageViewer({super.key, required this.image});

  static Future<void> show(BuildContext context, CapturedImageData image) =>
      pushFrameViewer(
        context,
        // absolute: fullscreen image is viewed on pure black, not theme surface
        barrierColor: ImageOverlayColors.shadow,
        transitionDuration: const Duration(milliseconds: 180),
        builder: (_) => FullscreenImageViewer(image: image),
      );

  @override
  Widget build(BuildContext context) =>
      FrameViewerKeys(child: _buildViewer(context, SkotiqColors.of(context)));

  Widget _buildViewer(BuildContext context, SkotiqColors colors) {
    return Scaffold(
      // absolute: image canvas backdrop stays pure black regardless of theme
      backgroundColor: ImageOverlayColors.shadow,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 8.0,
              child: Center(
                child: ImageDisplayWidget(
                  imageData: image,
                  zoomLevel: 1.0,
                  panOffset: Offset.zero,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: colors.surface.withValues(alpha: 0.72),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: Icon(
                      SkotiqIcons.close,
                      color: colors.textPrimary,
                      // The tooltip alone does not reach assistive tech.
                      semanticLabel: 'Close fullscreen image',
                    ),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
