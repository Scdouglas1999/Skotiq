import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/astro_image_viewer.dart';

part 'flat_preview_panel_parts/_stats_and_status.dart';
part 'flat_preview_panel_parts/_convergence_and_filters.dart';

class FlatPreviewPanel extends ConsumerWidget {
  const FlatPreviewPanel({super.key});

  /// Below this height the panel scrolls with fixed regions.
  static const double _shortThreshold = 560;

  /// Frame height in the scrolled (short) layout.
  static const double _shortPreviewHeight = 260;

  /// Convergence height in the scrolled (short) layout: room for the section
  /// title, the panel padding and an empty state.
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

        // A short region (a phone in landscape) or one with no height of its
        // own (a phone sheet, which scrolls its content) gets fixed heights:
        // a flex split has nothing to divide there.
        final bounded = constraints.maxHeight.isFinite;
        final isShort = !bounded || constraints.maxHeight < _shortThreshold;

        const gap = SizedBox(height: SkotiqTokens.spaceLg);

        if (isShort) {
          final stacked = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: _shortPreviewHeight, child: imagePreview),
              gap,
              statsBar,
              if (countdown != null) countdown,
              gap,
              SizedBox(
                height: _shortVisualizationsHeight,
                child: visualizations,
              ),
            ],
          );
          return bounded ? SingleChildScrollView(child: stacked) : stacked;
        }

        return Column(
          children: [
            Expanded(flex: 3, child: imagePreview),
            gap,
            statsBar,
            if (countdown != null) countdown,
            gap,
            Expanded(flex: 2, child: visualizations),
          ],
        );
      },
    );
  }
}

/// An empty state in the middle of the area it replaces. It scrolls, so a
/// short area (a phone sheet, a sheet that is still opening) cannot overflow.
class _CenteredEmptyState extends StatelessWidget {
  const _CenteredEmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight:
                constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: EmptyState.compact(icon: icon, title: title, body: body),
          ),
        ),
      ),
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
    // panel radius.
    return SkotiqPanel(
      flush: true,
      child: Stack(
        children: [
          Positioned.fill(
            child: imageResult != null
                ? _buildImage(imageResult, colors)
                : _buildEmptyState(),
          ),
          if (showHistogram && imageResult != null)
            Positioned(
              top: SkotiqTokens.spaceMd,
              right: SkotiqTokens.spaceMd,
              child: _buildHistogramOverlay(imageResult, colors),
            ),
        ],
      ),
    );
  }

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
    return const _CenteredEmptyState(
      icon: LucideIcons.image,
      title: 'No flat captured yet',
      body: 'The latest frame of a run shows here.',
    );
  }

  /// Size of the histogram laid over the frame.
  static const Size _histogramSize = Size(200, 120);

  Widget _buildHistogramOverlay(
      CapturedImageResult result, SkotiqColors colors) {
    final axis = SkotiqTypography.monoXs.copyWith(color: colors.textMuted);
    return Container(
      width: _histogramSize.width,
      height: _histogramSize.height,
      padding: SkotiqTokens.paddingSm,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'HISTOGRAM',
                style: SkotiqTypography.eyebrow
                    .copyWith(color: colors.textMuted),
              ),
              Text(
                'mean ${result.stats.mean.toStringAsFixed(0)} ADU',
                style: axis.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Expanded(
            child: _HistogramChart(
              histogram: result.histogram,
              colors: colors,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text('0', style: axis), Text('255', style: axis)],
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
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        ),
        child: Center(
          child: Text(
            'No data',
            style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      child: CustomPaint(
        painter: _HistogramPainter(
          histogram: histogram,
          barColor: colors.primary.withValues(alpha: 0.7),
          backgroundColor: colors.well,
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
