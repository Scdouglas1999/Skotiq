// Catalog overlay widget for the imaging preview (F5-CATALOG-OVERLAY).
//
// Composes three things:
//   * A `CustomPaint` that draws one marker per projected catalog object
//   * A `MouseRegion` + `GestureDetector` for hover-tooltip and click
//   * A `_CatalogObjectDetailsPanel` shown on selection
//
// Why a separate widget (not part of `AnnotationOverlay`): the existing
// annotation overlay paints objects that came out of the slow SIMBAD /
// Hyperleda annotation pipeline and live inside an `ImageAnnotation`
// snapshot. The catalog overlay is a live projection that doesn't
// touch the annotation snapshot — keeping it on its own pipeline means
// users can run it without re-annotating and the two systems never
// stomp on each other.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../utils/preview_transform.dart';

part 'catalog_overlay_widget/details_panel.dart';

const _markerStrokeWidth = 1.5;
const _markerColor = Color(0xFFFFE082); // soft amber
const _markerStarColor = Color(0xFFB3E5FC); // light blue for stars
const _labelColor = Color(0xFFFFFFFF);
const _labelShadow = Color(0xFF000000);

/// Widget that paints the catalog overlay on top of the captured image.
///
/// Inputs:
///   * [wcs] — solved WCS for the current frame. When null or invalid,
///     the widget renders an informational banner instead of markers.
///   * [zoomLevel] / [imageOffset] / [imageSize] — same view-transform
///     state the existing annotation overlay consumes.
class CatalogOverlayWidget extends ConsumerWidget {
  final SolvedWcs? wcs;
  final double zoomLevel;
  final Offset imageOffset;
  final Size imageSize;

  /// Whether to render a fallback banner in the corner of the preview
  /// when the WCS isn't usable or the catalog is missing. Defaults to
  /// true — the mission requires errors to surface rather than hide.
  final bool showFallbackBanner;

  const CatalogOverlayWidget({
    super.key,
    required this.wcs,
    required this.zoomLevel,
    required this.imageOffset,
    required this.imageSize,
    this.showFallbackBanner = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(catalogOverlayEnabledProvider);
    if (!enabled) return const SizedBox.shrink();

    final w = wcs;
    if (w == null || !w.isValid) {
      if (!showFallbackBanner) return const SizedBox.shrink();
      return const CatalogOverlayBanner(
        icon: LucideIcons.alertTriangle,
        title: 'Catalog overlay unavailable',
        message: 'Solve this frame to project catalog objects.',
      );
    }

    final magnitudeLimit = ref.watch(catalogOverlayMagnitudeLimitProvider);
    final includeStars = ref.watch(catalogOverlayIncludeStarsProvider);
    final includeDsos = ref.watch(catalogOverlayIncludeDsosProvider);

    if (!includeStars && !includeDsos) {
      return const CatalogOverlayBanner(
        icon: LucideIcons.layers,
        title: 'No catalog layers selected',
        message: 'Enable DSOs or bright stars in catalog overlay settings.',
      );
    }

    final query = CatalogOverlayQuery(
      wcs: w,
      magnitudeLimit: magnitudeLimit,
      includeStars: includeStars,
      includeDsos: includeDsos,
    );
    final async = ref.watch(catalogOverlayQueryProvider(query));

    return async.when(
      loading: () => CatalogOverlayBanner(
        icon: LucideIcons.loader,
        title: 'Loading catalog…',
        message: 'Querying ${magnitudeLimit.toStringAsFixed(0)} mag objects',
      ),
      error: (err, _) => CatalogOverlayBanner(
        icon: LucideIcons.alertCircle,
        title: 'Catalog overlay failed',
        message: err.toString(),
        tone: CatalogOverlayBannerTone.error,
      ),
      data: (result) {
        if (!result.catalogAvailable) {
          return const CatalogOverlayBanner(
            icon: LucideIcons.download,
            title: 'No catalog installed',
            message: 'Install the planetarium catalog in Settings → Catalogs.',
          );
        }
        final missingRequestedSource =
            (includeDsos && !result.dsoCatalogAvailable) ||
                (includeStars && !result.starCatalogAvailable);
        if (result.objects.isEmpty && missingRequestedSource) {
          return CatalogOverlayBanner(
            icon: LucideIcons.download,
            title: 'Selected catalog missing',
            message: _missingCatalogMessage(
              includeDsos: includeDsos,
              includeStars: includeStars,
              dsoCatalogAvailable: result.dsoCatalogAvailable,
              starCatalogAvailable: result.starCatalogAvailable,
            ),
          );
        }
        return _CatalogOverlayLayer(
          result: result,
          zoomLevel: zoomLevel,
          imageOffset: imageOffset,
          imageSize: imageSize,
        );
      },
    );
  }

  static String _missingCatalogMessage({
    required bool includeDsos,
    required bool includeStars,
    required bool dsoCatalogAvailable,
    required bool starCatalogAvailable,
  }) {
    if (includeDsos && !dsoCatalogAvailable) {
      return 'Install the DSO catalog in Settings > Catalogs.';
    }
    if (includeStars && !starCatalogAvailable) {
      return 'Install the HYG star catalog in Settings > Catalogs.';
    }
    return 'Install the selected catalog in Settings > Catalogs.';
  }
}

class _CatalogOverlayLayer extends ConsumerStatefulWidget {
  final CatalogOverlayResult result;
  final double zoomLevel;
  final Offset imageOffset;
  final Size imageSize;

  const _CatalogOverlayLayer({
    required this.result,
    required this.zoomLevel,
    required this.imageOffset,
    required this.imageSize,
  });

  @override
  ConsumerState<_CatalogOverlayLayer> createState() =>
      _CatalogOverlayLayerState();
}

class _CatalogOverlayLayerState extends ConsumerState<_CatalogOverlayLayer> {
  CatalogOverlayObject? _hovered;
  Offset _hoverScreenPoint = Offset.zero;

  static bool get _isTouchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  CatalogOverlayObject? _hitTest(Offset localPosition) {
    final imagePoint = viewportToImage(
      viewportPoint: localPosition,
      imageOffset: widget.imageOffset,
      zoomLevel: widget.zoomLevel,
    );
    CatalogOverlayObject? best;
    var bestDistanceSq = double.infinity;
    for (final obj in widget.result.objects) {
      final dx = obj.imageX - imagePoint.dx;
      final dy = obj.imageY - imagePoint.dy;
      final distSq = dx * dx + dy * dy;
      final radius = obj.hitRadius;
      if (distSq <= radius * radius && distSq < bestDistanceSq) {
        bestDistanceSq = distSq;
        best = obj;
      }
    }
    return best;
  }

  void _onHover(PointerEvent event) {
    final hit = _hitTest(event.localPosition);
    if (hit != _hovered) {
      setState(() {
        _hovered = hit;
        _hoverScreenPoint = event.localPosition;
      });
    } else if (hit != null) {
      setState(() => _hoverScreenPoint = event.localPosition);
    }
  }

  void _onExit(PointerEvent _) {
    if (_hovered != null) setState(() => _hovered = null);
  }

  void _onTapUp(TapUpDetails details) {
    final hit = _hitTest(details.localPosition);
    if (hit != null) {
      ref.read(selectedCatalogOverlayObjectProvider.notifier).state = hit;
    }
  }

  @override
  void didUpdateWidget(covariant _CatalogOverlayLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = ref.read(selectedCatalogOverlayObjectProvider);
    if (selected == null) return;
    final stillVisible = widget.result.objects.any(
      (obj) =>
          obj.id == selected.id &&
          obj.source == selected.source &&
          obj.imageX == selected.imageX &&
          obj.imageY == selected.imageY,
    );
    if (!stillVisible) {
      ref.read(selectedCatalogOverlayObjectProvider.notifier).state = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colors = context.skotiqColors;
        final tooltipMaxWidth = clampPanelWidth(
          constraints.maxWidth,
          fraction: 0.35,
          min: 160,
          max: 260,
        );

        final paint = CustomPaint(
          painter: CatalogOverlayPainter(
            objects: widget.result.objects,
            zoomLevel: widget.zoomLevel,
            imageOffset: widget.imageOffset,
            highlighted: _hovered,
          ),
          size: Size.infinite,
        );

        final children = <Widget>[];

        if (_isTouchPlatform) {
          children.add(
            GestureDetector(
              onTapUp: _onTapUp,
              behavior: HitTestBehavior.translucent,
              child: paint,
            ),
          );
        } else {
          children.add(
            MouseRegion(
              onHover: _onHover,
              onExit: _onExit,
              child: GestureDetector(
                onTapUp: _onTapUp,
                behavior: HitTestBehavior.translucent,
                child: paint,
              ),
            ),
          );
        }

        if (_hovered != null) {
          children.add(
            Positioned(
              left: _hoverScreenPoint.dx + 14,
              top: _hoverScreenPoint.dy + 14,
              child: IgnorePointer(
                child: _CatalogObjectTooltip(
                  object: _hovered!,
                  maxWidth: tooltipMaxWidth,
                ),
              ),
            ),
          );
        }

        children.add(
          Positioned(
            right: 12,
            top: 88,
            child: _CatalogOverlayHud(result: widget.result),
          ),
        );

        children.add(
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: CatalogOverlayDetailsPanel(colors: colors),
          ),
        );

        return Stack(children: children);
      },
    );
  }
}

/// Painter exposed for widget tests to inspect or invoke directly.
@visibleForTesting
class CatalogOverlayPainter extends CustomPainter {
  final List<CatalogOverlayObject> objects;
  final double zoomLevel;
  final Offset imageOffset;
  final CatalogOverlayObject? highlighted;

  CatalogOverlayPainter({
    required this.objects,
    required this.zoomLevel,
    required this.imageOffset,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const labelStyle = TextStyle(
      color: _labelColor,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      shadows: [
        Shadow(blurRadius: 3, color: _labelShadow, offset: Offset(1, 1)),
        Shadow(blurRadius: 6, color: _labelShadow),
      ],
    );

    for (final obj in objects) {
      final centre = imageToViewport(
        imagePoint: Offset(obj.imageX, obj.imageY),
        imageOffset: imageOffset,
        zoomLevel: zoomLevel,
      );
      final isHighlighted = identical(obj, highlighted);
      final color =
          obj.kind == CatalogOverlayKind.star ? _markerStarColor : _markerColor;

      final markerSize = _markerSizeFor(obj);
      _drawMarker(canvas, centre, obj.kind, markerSize, color, isHighlighted);
      _drawLabel(canvas, centre, obj, markerSize, labelStyle);
    }
  }

  double _markerSizeFor(CatalogOverlayObject obj) {
    return obj.markerRadiusPx * 2.0 * zoomLevel;
  }

  void _drawMarker(
    Canvas canvas,
    Offset centre,
    CatalogOverlayKind kind,
    double size,
    Color color,
    bool highlighted,
  ) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth =
          highlighted ? _markerStrokeWidth + 1.0 : _markerStrokeWidth
      ..color = color.withValues(alpha: highlighted ? 1.0 : 0.85);

    switch (kind) {
      case CatalogOverlayKind.star:
        _drawCross(canvas, centre, size, paint);
        break;
      case CatalogOverlayKind.galaxy:
        canvas.save();
        canvas.translate(centre.dx, centre.dy);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: size,
            height: size * 0.55,
          ),
          paint,
        );
        canvas.restore();
        break;
      case CatalogOverlayKind.openCluster:
        canvas.drawCircle(centre, size / 2, paint);
        final dotPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = paint.color;
        canvas.drawCircle(
            centre + Offset(-size * 0.15, -size * 0.1), 1.5, dotPaint);
        canvas.drawCircle(
            centre + Offset(size * 0.1, -size * 0.12), 1.5, dotPaint);
        canvas.drawCircle(
            centre + Offset(size * 0.12, size * 0.1), 1.5, dotPaint);
        canvas.drawCircle(
            centre + Offset(-size * 0.08, size * 0.12), 1.5, dotPaint);
        break;
      case CatalogOverlayKind.globularCluster:
        canvas.drawCircle(centre, size / 2, paint);
        // Plus sign through the circle — standard globular notation.
        final crossPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = paint.strokeWidth * 0.8
          ..color = paint.color;
        canvas.drawLine(
          centre + Offset(-size / 2, 0),
          centre + Offset(size / 2, 0),
          crossPaint,
        );
        canvas.drawLine(
          centre + Offset(0, -size / 2),
          centre + Offset(0, size / 2),
          crossPaint,
        );
        break;
      case CatalogOverlayKind.planetaryNebula:
        canvas.drawCircle(centre, size / 2, paint);
        canvas.drawCircle(centre, size / 6, paint);
        break;
      case CatalogOverlayKind.nebula:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: centre, width: size, height: size * 0.8),
            Radius.circular(size * 0.25),
          ),
          paint,
        );
        break;
      case CatalogOverlayKind.supernovaRemnant:
        canvas.drawCircle(centre, size / 2, paint);
        for (var i = 0; i < 6; i++) {
          final angle = (i / 6) * 2 * math.pi;
          final out = size / 2 + 4;
          final inn = size / 2;
          canvas.drawLine(
            centre + Offset(out * math.cos(angle), out * math.sin(angle)),
            centre + Offset(inn * math.cos(angle), inn * math.sin(angle)),
            paint,
          );
        }
        break;
      case CatalogOverlayKind.other:
        canvas.drawCircle(centre, size / 2, paint);
        break;
    }
  }

  void _drawCross(Canvas canvas, Offset centre, double size, Paint paint) {
    final half = size / 2;
    canvas.drawLine(
      centre + Offset(-half, 0),
      centre + Offset(half, 0),
      paint,
    );
    canvas.drawLine(
      centre + Offset(0, -half),
      centre + Offset(0, half),
      paint,
    );
  }

  void _drawLabel(
    Canvas canvas,
    Offset centre,
    CatalogOverlayObject obj,
    double markerSize,
    TextStyle style,
  ) {
    final label = obj.magnitude == null
        ? obj.displayName
        : '${obj.displayName}  ${obj.magnitude!.toStringAsFixed(1)}';

    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    final offset = Offset(
      centre.dx - painter.width / 2,
      centre.dy + markerSize / 2 + 4,
    );
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant CatalogOverlayPainter oldDelegate) {
    return oldDelegate.objects != objects ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.imageOffset != imageOffset ||
        oldDelegate.highlighted != highlighted;
  }
}

class _CatalogObjectTooltip extends StatelessWidget {
  final CatalogOverlayObject object;
  final double maxWidth;

  const _CatalogObjectTooltip({
    required this.object,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceOverlay.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            object.displayName,
            style: const TextStyle(
              color: _labelColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (object.commonName != null && object.id != object.commonName)
            Text(
              object.id,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 11,
              ),
            ),
          if (object.magnitude != null)
            _kvLine('Mag', object.magnitude!.toStringAsFixed(2)),
          if (object.sizeArcMin != null)
            _kvLine('Size', "${object.sizeArcMin!.toStringAsFixed(1)}'"),
          _kvLine('Catalog', object.source),
        ],
      ),
    );
  }

  Widget _kvLine(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$k: ',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 11,
            ),
          ),
          Text(
            v,
            style: const TextStyle(
              color: _labelColor,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _CatalogOverlayHud extends StatelessWidget {
  final CatalogOverlayResult result;
  const _CatalogOverlayHud({required this.result});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceOverlay.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Catalog overlay',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${result.objects.length} of ${result.totalInFov}'
            ' object${result.totalInFov == 1 ? '' : 's'}'
            ' ≤ mag ${result.appliedMagnitudeLimit.toStringAsFixed(1)}',
            style: const TextStyle(
              color: _labelColor,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (result.wasDownsampled)
            Text(
              'Showing brightest (cutoff mag '
              '${result.downsampleMagnitudeCutoff!.toStringAsFixed(2)})',
              style: TextStyle(
                color: Colors.amber.withValues(alpha: 0.9),
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

/// Banner widget exposed publicly so the catalog overlay toolbar button
/// can render the same informational style even before the overlay
/// renders any markers.
class CatalogOverlayBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final CatalogOverlayBannerTone tone;

  const CatalogOverlayBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.tone = CatalogOverlayBannerTone.info,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final accent =
        tone == CatalogOverlayBannerTone.error ? colors.error : colors.info;
    return Stack(
      children: [
        Positioned(
          top: 88,
          right: 12,
          child: _bannerCard(context, colors, accent),
        ),
      ],
    );
  }

  Widget _bannerCard(
    BuildContext context,
    SkotiqColors colors,
    Color accent,
  ) {
    final bannerMaxWidth = clampPanelWidth(
      MediaQuery.sizeOf(context).width,
      fraction: 0.35,
      min: 200,
      max: 280,
    );

    return Container(
      constraints: BoxConstraints(maxWidth: bannerMaxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceOverlay.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _labelColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum CatalogOverlayBannerTone { info, error }

/// Toolbar dropdown widget — exposes the magnitude limit / star toggle /
/// DSO toggle as a popover so the LivePreviewArea's overflow stays sane.
class CatalogOverlayPopover extends ConsumerWidget {
  final SkotiqColors colors;
  const CatalogOverlayPopover({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final magnitudeLimit = ref.watch(catalogOverlayMagnitudeLimitProvider);
    final includeDsos = ref.watch(catalogOverlayIncludeDsosProvider);
    final includeStars = ref.watch(catalogOverlayIncludeStarsProvider);

    final popoverWidth = clampPanelWidth(
      MediaQuery.sizeOf(context).width,
      fraction: 0.3,
      min: 200,
      max: 240,
    );

    return SizedBox(
      width: popoverWidth,
      child: SkotiqCard(
        variant: CardVariant.elevated,
        borderRadius: SkotiqTokens.radiusMd,
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Catalog overlay',
              style: SkotiqTypography.label.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              'Magnitude limit',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            SkotiqDropdown(
              isExpanded: true,
              isDense: true,
              value: _snapMagnitude(magnitudeLimit).toStringAsFixed(0),
              items: const [
                '6',
                '8',
                '10',
                '12',
                '14',
              ],
              itemLabels: const [
                'Mag <= 6',
                'Mag <= 8',
                'Mag <= 10',
                'Mag <= 12',
                'Mag <= 14',
              ],
              onChanged: (v) {
                if (v == null) return;
                final magnitude = double.tryParse(v);
                if (magnitude == null) return;
                ref.read(catalogOverlayMagnitudeLimitProvider.notifier).state =
                    magnitude;
              },
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqSwitchRow(
              label: 'DSOs (Messier / NGC / IC)',
              value: includeDsos,
              compact: true,
              onChanged: (v) => ref
                  .read(catalogOverlayIncludeDsosProvider.notifier)
                  .state = v,
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqSwitchRow(
              label: 'Bright stars (HYG)',
              value: includeStars,
              compact: true,
              onChanged: (v) => ref
                  .read(catalogOverlayIncludeStarsProvider.notifier)
                  .state = v,
            ),
          ],
        ),
      ),
    );
  }

  static double _snapMagnitude(double v) {
    // Pick the closest dropdown bucket so an arbitrary numeric value
    // from a saved session still maps to a valid menu entry.
    const buckets = <double>[6, 8, 10, 12, 14];
    var best = buckets.first;
    var bestDelta = (v - best).abs();
    for (final b in buckets.skip(1)) {
      final d = (v - b).abs();
      if (d < bestDelta) {
        best = b;
        bestDelta = d;
      }
    }
    return best;
  }
}
