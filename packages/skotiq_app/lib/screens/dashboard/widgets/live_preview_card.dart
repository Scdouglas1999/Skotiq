import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/astro_image_viewer.dart';
import 'glass_card.dart';

/// Live preview card - orchestrates smaller focused widgets
///
/// Uses a responsive aspect ratio for the image preview area that adapts
/// to the available width:
/// - Wide screens (>800px): 16:9 aspect ratio for cinematic preview
/// - Medium screens (400-800px): 4:3 aspect ratio for balanced view
/// - Narrow screens (<400px): 1:1 aspect ratio for compact display
///
/// The card fills the available width in its parent container.
class LivePreviewCard extends StatelessWidget {
  final SkotiqColors colors;
  final AnimationController pulseController;

  const LivePreviewCard({
    super.key,
    required this.colors,
    required this.pulseController,
  });

  /// Calculate responsive aspect ratio based on available width.
  double _getAspectRatio(double width) {
    if (width > 800) {
      // Wide screens: 16:9 cinematic aspect ratio
      return 16 / 9;
    } else if (width > 400) {
      // Medium screens: 4:3 balanced aspect ratio
      return 4 / 3;
    } else {
      // Narrow screens: 1:1 square aspect ratio
      return 1.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DashboardGlassCard(
      colors: colors,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final aspectRatio = _getAspectRatio(availableWidth);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row - compact
              DashboardCardHeader(
                colors: colors,
                icon: LucideIcons.image,
                title: context.l10n.text('livePreview'),
                accent: colors.primary,
                trailing: _CaptureStatusIndicator(
                  colors: colors,
                  pulseController: pulseController,
                ),
              ),

              const SizedBox(height: DashboardCardStyle.headerGap),

              // Image preview area - constrained height to prevent dominating screen
              // Max height of 400px ensures space for other content
              // On very narrow screens (<320px), use smaller min height
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: 400,
                  minHeight: availableWidth < 320 ? 150 : 200,
                ),
                child: AspectRatio(
                  aspectRatio: aspectRatio,
                  child: _ImagePreviewArea(colors: colors),
                ),
              ),

              const SizedBox(height: 10),

              // Stats row
              _ImageStatsRow(colors: colors),
            ],
          );
        },
      ),
    );
  }
}

/// Capture status indicator - only rebuilds when capture state changes
class _CaptureStatusIndicator extends ConsumerWidget {
  final SkotiqColors colors;
  final AnimationController pulseController;

  const _CaptureStatusIndicator({
    required this.colors,
    required this.pulseController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exposurePercent =
        ref.watch(exposureProgressProvider.select((s) => s.percent));
    final isDownloading =
        ref.watch(exposureProgressProvider.select((s) => s.isDownloading));
    final isSessionCapturing =
        ref.watch(sessionStateProvider.select((s) => s.isCapturing));

    final isCapturing =
        isSessionCapturing || exposurePercent > 0 || isDownloading;

    return Row(
      children: [
        AnimatedBuilder(
          animation: pulseController,
          builder: (context, child) {
            return Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isCapturing
                    ? colors.success
                        .withValues(alpha: 0.3 + pulseController.value * 0.4)
                    : colors.textMuted
                        .withValues(alpha: 0.3 + pulseController.value * 0.4),
              ),
            );
          },
        ),
        const SizedBox(width: 8),
        Text(
          isCapturing
              ? context.l10n.text('capturing')
              : context.l10n.text('idle'),
          style: SkotiqTypography.caption.copyWith(
              color: isCapturing ? colors.success : colors.textSecondary),
        ),
      ],
    );
  }
}

/// Image preview area - only rebuilds when image or camera connection changes
class _ImagePreviewArea extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _ImagePreviewArea({required this.colors});

  @override
  ConsumerState<_ImagePreviewArea> createState() => _ImagePreviewAreaState();
}

class _ImagePreviewAreaState extends ConsumerState<_ImagePreviewArea> {
  double _currentZoom = 1.0;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final currentImage = ref.watch(currentImageProvider);
    final isConnected =
        ref.watch(cameraStateProvider.select((s) => s.connectionState)) ==
            DeviceConnectionState.connected;

    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        child: Stack(
          children: [
            if (currentImage != null)
              Positioned.fill(
                child: AstroImageViewer(
                  imageData: currentImage.displayData,
                  width: currentImage.width,
                  height: currentImage.height,
                  isColor: currentImage.isColor,
                  minScale: 0.1,
                  maxScale: 10.0,
                  enableInteraction: true,
                  onTransformChanged: (controller) {
                    final scale = controller.value.getMaxScaleOnAxis();
                    if ((scale - _currentZoom).abs() > 0.01) {
                      setState(() => _currentZoom = scale);
                    }
                  },
                ),
              )
            else ...[
              CustomPaint(
                painter: _StarFieldPainter(colors: colors),
                size: Size.infinite,
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colors.surface.withValues(alpha: 0.8),
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.border),
                      ),
                      child: Icon(LucideIcons.camera,
                          size: 32, color: colors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isConnected
                          ? context.l10n.text('noImage')
                          : context.l10n.text('noCameraConnected'),
                      style: SkotiqTypography.button
                          .copyWith(color: colors.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isConnected
                          ? context.l10n.text('takeSnapshotOrStartSequence')
                          : context.l10n.text('connectCameraInEquipment'),
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
            // Zoom indicator overlay in top-left
            if (currentImage != null)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.85),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    border:
                        Border.all(color: colors.border.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    '${(_currentZoom * 100).toInt()}%',
                    // A zoom percentage is a readout, so it takes the mono
                    // caption style rather than a hand-rolled 'monospace'
                    // family the app does not otherwise ship.
                    style: SkotiqTypography.monoCaption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            // Resolution overlay in top-right
            if (currentImage != null)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.85),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    border:
                        Border.all(color: colors.border.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    '${currentImage.width} × ${currentImage.height}',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Image stats row - only rebuilds when image stats change
class _ImageStatsRow extends ConsumerWidget {
  final SkotiqColors colors;

  const _ImageStatsRow({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastStats = ref.watch(lastImageStatsProvider);
    final currentImage = ref.watch(currentImageProvider);

    // Get image dimensions from current image
    final width = currentImage?.width;
    final height = currentImage?.height;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          // Top row - Image info
          Row(
            children: [
              _StatCell(
                  label: 'Size',
                  value: width != null && height != null
                      ? '${width}x$height'
                      : kReadoutUnknown,
                  colors: colors),
              _StatCell(
                  label: 'Stars',
                  value: lastStats?.starCount?.toString() ?? kReadoutUnknown,
                  colors: colors),
              _StatCell(
                  label: 'HFR',
                  value: lastStats?.hfr?.toStringAsFixed(2) ?? kReadoutUnknown,
                  colors: colors,
                  highlight: true),
              _StatCell(
                  label: 'FWHM',
                  value: lastStats?.fwhm?.toStringAsFixed(2) ?? kReadoutUnknown,
                  colors: colors),
            ],
          ),
          const SizedBox(height: 4),
          // Bottom row - Pixel stats
          Row(
            children: [
              _StatCell(
                  label: 'Mean',
                  value: lastStats?.mean?.toStringAsFixed(0) ?? kReadoutUnknown,
                  colors: colors),
              _StatCell(
                  label: 'Median',
                  value:
                      lastStats?.median?.toStringAsFixed(0) ?? kReadoutUnknown,
                  colors: colors),
              _StatCell(
                  label: 'Min',
                  value: lastStats?.min?.toStringAsFixed(0) ?? kReadoutUnknown,
                  colors: colors),
              _StatCell(
                  label: 'Max',
                  value: lastStats?.max?.toStringAsFixed(0) ?? kReadoutUnknown,
                  colors: colors),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact stat cell for the statistics grid
class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool highlight;

  const _StatCell({
    required this.label,
    required this.value,
    required this.colors,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: SkotiqTypography.h6.copyWith(
              color: highlight ? colors.primary : colors.textPrimary,
            ),
          ),
          Text(
            label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _StarFieldPainter extends CustomPainter {
  final SkotiqColors colors;

  _StarFieldPainter({required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);
    final paint = Paint();

    for (var i = 0; i < 50; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final brightness = random.nextDouble() * 0.3 + 0.1;
      final radius = random.nextDouble() * 1.5 + 0.5;

      // absolute: simulated stars drawn over the dark preview canvas
      paint.color = Colors.white.withValues(alpha: brightness);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
