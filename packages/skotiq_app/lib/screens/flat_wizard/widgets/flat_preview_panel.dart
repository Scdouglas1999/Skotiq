import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/astro_image_viewer.dart';

part 'flat_preview_panel_parts/_stats_and_status.dart';
part 'flat_preview_panel_parts/_convergence_and_filters.dart';

class FlatPreviewPanel extends ConsumerWidget {
  const FlatPreviewPanel({super.key});

  /// Below this height the panel scrolls with fixed regions instead of
  /// fighting a flex split for pixels.
  static const double _shortThreshold = 560;

  /// Frame height in the scrolled (short) layout.
  static const double _shortPreviewHeight = 260;

  /// Convergence height in the scrolled (short) layout. Sized so the section
  /// title, the panel padding and an EmptyState all fit: at 220 the empty
  /// state was clipped by 200px.
  static const double _shortVisualizationsHeight = 300;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final imagePreview = _ImagePreview(
          imageData: state.lastImageData,
          showHistogram: state.showHistogramOverlay,
        );
        final statsBar = _StatsBar(state: state);
        final countdown =
            state.isExposing ? _ExposureCountdown(state: state) : null;
        final visualizations = _VisualizationsSection(state: state);

        // When the region is short (phone preview pane / landscape), the
        // flex split would crush the visualization charts into overflow.
        // Below a threshold, scroll the panel with sensible fixed heights
        // instead of fighting for pixels.
        final isShort = constraints.maxHeight.isFinite &&
            constraints.maxHeight < _shortThreshold;

        if (isShort) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: _shortPreviewHeight, child: imagePreview),
                statsBar,
                if (countdown != null) countdown,
                SizedBox(
                  height: _shortVisualizationsHeight,
                  child: visualizations,
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            Expanded(flex: 3, child: imagePreview),
            statsBar,
            if (countdown != null) countdown,
            Expanded(flex: 2, child: visualizations),
          ],
        );
      },
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final dynamic imageData;
  final bool showHistogram;

  const _ImagePreview({
    required this.imageData,
    required this.showHistogram,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Attempt to extract CapturedImageResult from the dynamic imageData field.
    // The flat wizard screen stores either a CapturedImageResult or raw Uint8List
    // depending on how setLastImage was called. We handle both for robustness.
    final CapturedImageResult? imageResult = _extractImageResult();

    // A flush panel: the frame runs edge to edge under it, clipped to the
    // panel radius (02 rule 1, 05 §1).
    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: SkotiqPanel(
        flush: true,
        child: Stack(
          children: [
            // Image or empty state
            Positioned.fill(
              child: imageResult != null
                  ? _buildImage(imageResult, colors)
                  : _buildEmptyState(),
            ),

            // Histogram overlay (top right)
            if (showHistogram && imageResult != null)
              Positioned(
                top: SkotiqTokens.spaceMd,
                right: SkotiqTokens.spaceMd,
                child: _buildHistogramOverlay(imageResult, colors),
              ),
          ],
        ),
      ),
    );
  }

  /// Extract CapturedImageResult from the dynamic imageData field.
  /// Returns null if no valid image data is available.
  CapturedImageResult? _extractImageResult() {
    if (imageData == null) return null;
    if (imageData is CapturedImageResult) {
      return imageData as CapturedImageResult;
    }
    // If someone passed raw Uint8List (legacy path), we cannot render it
    // without width/height/isColor info, so treat as unavailable.
    return null;
  }

  Widget _buildImage(CapturedImageResult result, SkotiqColors colors) {
    final Uint8List displayBytes;
    if (result.displayData is Uint8List) {
      displayBytes = result.displayData as Uint8List;
    } else {
      displayBytes = Uint8List.fromList(result.displayData);
    }

    if (displayBytes.isEmpty || result.width <= 0 || result.height <= 0) {
      return _buildEmptyState();
    }

    return AstroImageViewer(
      imageData: displayBytes,
      width: result.width,
      height: result.height,
      isColor: result.isColor,
      enableInteraction: true,
      minScale: 0.1,
      maxScale: 10.0,
      filterQuality: FilterQuality.medium,
    );
  }

  Widget _buildEmptyState() {
    // The one empty-state pattern (05 §12), not a 64px icon over two hand-
    // toned Texts. Scroll-safe: when the preview region is short (phone), the
    // placeholder must not overflow its Stack/Positioned.fill bounds.
    return const SingleChildScrollView(
      child: Center(
        child: EmptyState.compact(
          icon: LucideIcons.image,
          title: 'No flat captured yet',
          body: 'Start a capture or a test exposure to see the frame here.',
        ),
      ),
    );
  }

  Widget _buildHistogramOverlay(
      CapturedImageResult result, SkotiqColors colors) {
    return Container(
      width: 200,
      height: 120,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Histogram',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  fontWeight: FontWeight.w600,
                  color: colors.textMuted,
                ),
              ),
              Text(
                'Mean: ${result.stats.mean.toStringAsFixed(0)} ADU',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize9,
                  color: colors.textSecondary,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _HistogramChart(
              histogram: result.histogram,
              colors: colors,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '0',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize8,
                  color: colors.textMuted,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                '255',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize8,
                  color: colors.textMuted,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Custom painter that renders a histogram from 256-bin data.
/// Uses logarithmic scaling to handle the wide dynamic range typical of
/// flat frame ADU distributions (dominant mid-range peak with low tails).
class _HistogramChart extends StatelessWidget {
  final List<int> histogram;
  final SkotiqColors colors;

  const _HistogramChart({
    required this.histogram,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    if (histogram.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
        ),
        child: Center(
          child: Text(
            'No data',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize9,
                color: colors.textMuted),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      child: CustomPaint(
        painter: _HistogramPainter(
          histogram: histogram,
          barColor: colors.primary.withValues(alpha: 0.7),
          backgroundColor: colors.surfaceAlt,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final List<int> histogram;
  final Color barColor;
  final Color backgroundColor;

  _HistogramPainter({
    required this.histogram,
    required this.barColor,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    if (histogram.isEmpty) return;

    // Use logarithmic scaling to visualize the histogram.
    // Flat frames typically have a very dominant peak in the mid-range,
    // and log scaling makes the full distribution visible.
    final binCount = histogram.length;
    final barWidth = size.width / binCount;

    // Find the maximum log value for normalization, skipping the first and
    // last bins which can contain clipped pixel counts that skew the scale.
    double maxLogVal = 0;
    for (int i = 1; i < binCount - 1; i++) {
      if (histogram[i] > 0) {
        final logVal = math.log(histogram[i] + 1);
        if (logVal > maxLogVal) {
          maxLogVal = logVal;
        }
      }
    }
    // Also check first/last bins but cap them at the interior max so they
    // don't dominate the chart if they contain clipped pixels.
    if (maxLogVal == 0) {
      // All bins (excluding edges) are zero; fall back to using edges
      for (int i = 0; i < binCount; i++) {
        if (histogram[i] > 0) {
          final logVal = math.log(histogram[i] + 1);
          if (logVal > maxLogVal) {
            maxLogVal = logVal;
          }
        }
      }
    }
    if (maxLogVal == 0) return; // No data at all

    final barPaint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;

    for (int i = 0; i < binCount; i++) {
      if (histogram[i] <= 0) continue;

      final logVal = math.log(histogram[i] + 1);
      final normalizedHeight = (logVal / maxLogVal).clamp(0.0, 1.0);
      final barHeight = normalizedHeight * size.height;

      canvas.drawRect(
        Rect.fromLTWH(
          i * barWidth,
          size.height - barHeight,
          barWidth,
          barHeight,
        ),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter oldDelegate) {
    return !identical(oldDelegate.histogram, histogram) ||
        oldDelegate.barColor != barColor ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
