import 'dart:io';

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;

/// The finished-master hero for the Morning Report: the stretched preview PNG
/// (loaded on-disk exactly like [MasterPreviewView]) under a [Stack] of
/// toggleable overlays — rejection map, coverage map, and a vector catalog
/// annotation layer drawn at each [Annotation]'s pixel position.
///
/// This is the post-session analogue of the live viewer but, like
/// `MasterPreviewView`, reads on-disk artifacts rather than an in-memory buffer
/// (the batch master never lives in the Dart heap). The image-map overlays blend
/// a second PNG at low opacity; the annotation layer is *vector* (labels +
/// ellipses), painted via [CustomPaint] in the un-zoomed image space and kept in
/// lock-step with the [InteractiveViewer]'s zoom/pan because it sits inside the
/// viewer's child subtree — the viewer's single `Transform` moves it. A shared
/// [TransformationController] drives a rebuild on zoom so stroke/label sizes can
/// be damped by 1/zoom (positions are never re-transformed here).
/// One finishing-result "after" layer for [MasterOverlayView]: a labelled,
/// full-frame preview PNG of a non-destructive finishing pass (background
/// extraction / deconvolution / star reduction) rendered beside its master.
class FinishingResultLayer {
  /// Chip label (e.g. `Background extract`, `Deconvolve`, `Reduce stars`).
  final String label;

  /// On-disk preview PNG of the finishing artifact (the sibling `.png` the
  /// controller rendered next to the `_bgx`/`_decon`/`_starred` FITS).
  final String pngPath;

  /// Chip icon.
  final IconData icon;

  const FinishingResultLayer({
    required this.label,
    required this.pngPath,
    required this.icon,
  });
}

/// The conventional sibling preview PNG for a finishing-artifact FITS at
/// [fitsPath]: the same path with a `.png` extension — what the controller's
/// finishing actions render beside each `_bgx`/`_decon`/`_starred` FITS.
String _siblingPng(String fitsPath) {
  final dir = p.dirname(fitsPath);
  final stem = p.basenameWithoutExtension(fitsPath);
  return p.join(dir, '$stem.png');
}

/// The finishing-result "after" layers for [master] that exist on disk — one
/// per persisted finishing FITS path (background extraction / deconvolution /
/// star reduction / colour calibration), pointing at its sibling preview PNG so
/// [MasterOverlayView] can A/B each pass against the raw master. Empty when no
/// master / no finishing artifacts have been produced. Shared by the workbench
/// and narrative session-review heroes.
List<FinishingResultLayer> finishingLayersForMaster(IntegratedMaster? master) {
  if (master == null) return const [];
  bool exists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  final out = <FinishingResultLayer>[];
  void add(String? fits, String label, IconData icon) {
    if (fits == null || fits.trim().isEmpty) return;
    final png = _siblingPng(fits);
    if (!exists(png)) return;
    out.add(FinishingResultLayer(label: label, pngPath: png, icon: icon));
  }

  add(master.backgroundExtractedPath, 'Background extract',
      SkotiqIcons.grid);
  add(master.deconvolvedPath, 'Deconvolve', SkotiqIcons.sparkle);
  add(master.starReducedPath, 'Reduce stars', SkotiqIcons.star);
  add(master.colorCalibratedPath, 'Color calibrate', SkotiqIcons.star);
  return out;
}

class MasterOverlayView extends StatefulWidget {
  /// Path to the stretched master preview PNG (the hero base layer).
  final String previewPngPath;

  /// Catalog annotation layer (labels at master pixel coords), or null.
  final AnnotationLayer? annotations;

  /// Path to the rejection-map PNG, or null when none was produced.
  final String? rejectionMapPngPath;

  /// Path to the coverage-map PNG, or null when none was produced.
  final String? coverageMapPngPath;

  /// Initial visibility of the annotation layer.
  final bool showAnnotations;

  /// Initial visibility of the rejection-map overlay.
  final bool showRejection;

  /// Initial visibility of the coverage-map overlay.
  final bool showCoverage;

  /// Optional finishing-result "after" layers — the background-extracted /
  /// deconvolved / star-reduced master previews. Each is a full-frame PNG that,
  /// when its chip is enabled, replaces the base preview at full opacity so the
  /// operator can A/B the finishing pass against the raw master (only one
  /// finishing layer shows at a time; toggling it off returns to the raw
  /// master). Entries whose PNG is not on disk are dropped.
  final List<FinishingResultLayer> finishingLayers;

  const MasterOverlayView({
    super.key,
    required this.previewPngPath,
    this.annotations,
    this.rejectionMapPngPath,
    this.coverageMapPngPath,
    this.showAnnotations = true,
    this.showRejection = false,
    this.showCoverage = false,
    this.finishingLayers = const [],
  });

  @override
  State<MasterOverlayView> createState() => _MasterOverlayViewState();
}

class _MasterOverlayViewState extends State<MasterOverlayView> {
  late bool _showAnnotations = widget.showAnnotations;
  late bool _showRejection = widget.showRejection;
  late bool _showCoverage = widget.showCoverage;

  /// The active finishing-result "after" layer (its preview replaces the base
  /// at full opacity), or null when showing the raw master. At most one
  /// finishing layer shows at a time so the operator A/Bs against the raw.
  FinishingResultLayer? _activeFinishing;

  // Shared with the annotation painter so labels track zoom/pan.
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  bool _exists(String? path) {
    if (path == null) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hasPreview = _exists(widget.previewPngPath);
    final hasRejection = _exists(widget.rejectionMapPngPath);
    final hasCoverage = _exists(widget.coverageMapPngPath);
    final layer = widget.annotations;
    final hasAnnotations = layer != null && layer.items.isNotEmpty;

    // Drop finishing layers whose preview PNG is no longer on disk, and forget
    // an active selection that vanished (the chip would otherwise stick lit).
    final finishing =
        widget.finishingLayers.where((f) => _exists(f.pngPath)).toList();
    final active = (_activeFinishing != null &&
            finishing.any((f) => f.pngPath == _activeFinishing!.pngPath))
        ? _activeFinishing
        : null;

    if (!hasPreview) {
      return EmptyState(
        icon: SkotiqIcons.imageOff,
        title: 'Preview not available',
        body: 'The master preview file is no longer on disk:\n'
            '${widget.previewPngPath}',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasRejection ||
            hasCoverage ||
            hasAnnotations ||
            finishing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceXs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (hasAnnotations)
                  _OverlayToggle(
                    icon: SkotiqIcons.target,
                    label: 'Annotations',
                    value: _showAnnotations,
                    onChanged: (v) => setState(() => _showAnnotations = v),
                  ),
                if (hasRejection)
                  _OverlayToggle(
                    icon: SkotiqIcons.layers,
                    label: 'Rejection',
                    value: _showRejection,
                    onChanged: (v) => setState(() => _showRejection = v),
                  ),
                if (hasCoverage)
                  _OverlayToggle(
                    icon: SkotiqIcons.grid,
                    label: 'Coverage',
                    value: _showCoverage,
                    onChanged: (v) => setState(() => _showCoverage = v),
                  ),
                // Finishing-result "after" layers: single-select (radio-like) so
                // exactly one replaces the raw master at a time; re-tapping the
                // lit chip returns to the raw master.
                for (final f in finishing)
                  _OverlayToggle(
                    icon: f.icon,
                    label: f.label,
                    value: active?.pngPath == f.pngPath,
                    onChanged: (v) => setState(
                      () => _activeFinishing = v ? f : null,
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            color: colors.background,
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: InteractiveViewer(
              transformationController: _transform,
              maxScale: 8,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(widget.previewPngPath),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Center(
                          child: Icon(SkotiqIcons.imageOff,
                              size: SkotiqTokens.icon2xl,
                              color: colors.textMuted),
                        ),
                      ),
                      // The active finishing pass replaces the raw master at
                      // full opacity (a true "after"); toggling the chip off
                      // drops back to the raw "before".
                      if (active != null)
                        Image.file(
                          File(active.pngPath),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      if (_showCoverage && hasCoverage)
                        Opacity(
                          opacity: SkotiqTokens.opacityHalf,
                          child: Image.file(
                            File(widget.coverageMapPngPath!),
                            fit: BoxFit.contain,
                          ),
                        ),
                      if (_showRejection && hasRejection)
                        Opacity(
                          opacity: 0.55,
                          child: Image.file(
                            File(widget.rejectionMapPngPath!),
                            fit: BoxFit.contain,
                          ),
                        ),
                      if (_showAnnotations && hasAnnotations)
                        AnimatedBuilder(
                          animation: _transform,
                          builder: (context, _) => CustomPaint(
                            painter: _AnnotationPainter(
                              layer: layer,
                              viewport: viewport,
                              transform: _transform.value,
                              colors: colors,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        if (active != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
              vertical: SkotiqTokens.spaceXs,
            ),
            child: Text(
              'Showing ${active.label} preview — toggle off for the raw master',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          ),
        if (hasAnnotations && _showAnnotations)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
              vertical: SkotiqTokens.spaceXs,
            ),
            child: Text(
              '${layer.items.length} catalog objects annotated',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          ),
      ],
    );
  }
}

/// A labelled overlay-visibility toggle (icon + name + [SkotiqSwitch]).
class _OverlayToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _OverlayToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: SkotiqTokens.iconXs,
            color: value ? colors.primary : colors.textSecondary),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Text(
          label,
          style:
              SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        SkotiqSwitch(value: value, compact: true, onChanged: onChanged),
      ],
    );
  }
}

/// Paints the vector catalog annotations (an ellipse sized [Annotation.sizePx],
/// rotated [Annotation.paDeg], plus the label) in the un-zoomed image space the
/// base `Image.file` occupies. This painter lives inside the
/// [InteractiveViewer]'s child subtree, so the viewer's single
/// `Transform(matrix)` is what moves the annotations under zoom/pan — the
/// painter must NOT re-apply that matrix (doing so double-transforms and slides
/// labels off their objects). The [transform] is read only to damp stroke/label
/// sizes by 1/zoom so they stay readable while the enclosing Transform scales
/// everything else.
class _AnnotationPainter extends CustomPainter {
  final AnnotationLayer layer;
  final Size viewport;
  final Matrix4 transform;
  final SkotiqColors colors;

  _AnnotationPainter({
    required this.layer,
    required this.viewport,
    required this.transform,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (layer.items.isEmpty || layer.width <= 0 || layer.height <= 0) return;

    // This CustomPaint lives INSIDE the InteractiveViewer's child subtree, so
    // the viewer's own `Transform(matrix)` already applies the zoom/pan to this
    // canvas. We must therefore paint in the SAME un-zoomed local space the base
    // `Image.file` occupies and let the enclosing Transform move the annotations
    // — applying the matrix a second time here would double-transform every
    // ellipse/label and slide them off their catalog objects under zoom/pan.
    //
    // The base image is laid out with BoxFit.contain inside [viewport]; the
    // shared `annotationContainScale` / `annotationLocalCenter` map annotation
    // pixels into that un-zoomed local rect. No `canvas.transform(...)` — the
    // enclosing InteractiveViewer Transform is the single source of zoom/pan.
    final scale = annotationContainScale(viewport, layer.width, layer.height);

    // The enclosing Transform scales strokes + labels with the zoom; damp them
    // by 1/zoom so they stay a constant on-screen size (readable, not ballooning)
    // even though positions are driven entirely by that single Transform.
    final zoom = transform.getMaxScaleOnAxis().clamp(0.5, 8.0);
    final labelScale = 1.0 / zoom;

    for (final a in layer.items) {
      final center =
          annotationLocalCenter(a, viewport, layer.width, layer.height);
      final cx = center.dx;
      final cy = center.dy;
      final color = _kindColor(a.kind);

      final rPx = (a.sizePx * scale) / 2;
      final rx = rPx <= 0 ? 6.0 : rPx;
      final ry = a.paDeg != null ? rx * 0.6 : rx;

      final markerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / zoom
        ..color = color.withValues(alpha: 0.9);

      canvas.save();
      canvas.translate(cx, cy);
      if (a.paDeg != null) {
        canvas.rotate(a.paDeg! * 3.1415926535897932 / 180.0);
      }
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
        markerPaint,
      );
      canvas.restore();

      if (a.label.isNotEmpty) {
        final span = TextSpan(
          text: a.label,
          style: SkotiqTypography.captionSm.copyWith(
            color: color,
            fontSize: SkotiqTypography.captionSm.fontSize! * labelScale,
            shadows: [
              Shadow(color: colors.background, blurRadius: 2 * labelScale),
            ],
          ),
        );
        final painter = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          Offset(cx - painter.width / 2, cy + rx + (2 * labelScale)),
        );
      }
    }
  }

  /// Maps an [AnnotationKind] to its catalog display hue via the design-system
  /// [AnnotationTypeColors] helper, falling back to a semantic token.
  Color _kindColor(AnnotationKind kind) {
    switch (kind) {
      case AnnotationKind.galaxy:
        return AnnotationTypeColors.galaxy;
      case AnnotationKind.nebula:
        return AnnotationTypeColors.nebula;
      case AnnotationKind.cluster:
        return AnnotationTypeColors.starCluster;
      case AnnotationKind.star:
        return AnnotationTypeColors.star;
      case AnnotationKind.other:
        return colors.textSecondary;
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) =>
      old.layer != layer ||
      old.transform != transform ||
      old.viewport != viewport;
}

/// The BoxFit.contain scale that maps a [layerWidth]×[layerHeight] image into
/// [viewport] — the same scale the base `Image.file` is laid out with. Shared by
/// the painter and exposed for the annotation-registration test.
@visibleForTesting
double annotationContainScale(
  Size viewport,
  int layerWidth,
  int layerHeight,
) {
  if (layerWidth <= 0 || layerHeight <= 0) return 0;
  return (viewport.width / layerWidth)
      .clamp(0.0, viewport.height / layerHeight);
}

/// The un-zoomed local-space centre of [a] inside [viewport] for a
/// [layerWidth]×[layerHeight] annotation layer. This is intentionally
/// **independent of the InteractiveViewer transform**: the painter sits inside
/// the viewer's child subtree, so the viewer's single `Transform(matrix)` moves
/// the annotation under zoom/pan — the painter must never re-apply that matrix.
/// The annotation-registration test asserts this center is identical at identity
/// and at a zoomed/panned transform, proving the matrix is applied exactly once.
@visibleForTesting
Offset annotationLocalCenter(
  Annotation a,
  Size viewport,
  int layerWidth,
  int layerHeight,
) {
  final scale = annotationContainScale(viewport, layerWidth, layerHeight);
  final drawnW = layerWidth * scale;
  final drawnH = layerHeight * scale;
  final originX = (viewport.width - drawnW) / 2;
  final originY = (viewport.height - drawnH) / 2;
  return Offset(originX + a.x * scale, originY + a.y * scale);
}
