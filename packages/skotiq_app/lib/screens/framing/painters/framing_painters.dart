import 'dart:math' as math;

import 'package:flutter/material.dart';
// FramingPlateScale is the C1 single-source-of-truth astrometric scale shared by
// every framing painter and the gesture hit-tester. It lives in skotiq_core's
// models layer and is not surfaced through the public barrel, so it is imported
// directly here, matching the established app->core src-model convention used by
// the sibling background painters in this same folder.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// FramingMosaicConfig / FramingMosaicPanel are exported from the public barrel.
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Equipment FOV rectangle drawn at the canvas center when the preview FOV is
/// at or below the equipment FOV. Includes corner markers, a rotation handle,
/// FOV dimensions, and optional cardinal directions.
///
/// The rectangle is scaled by the shared [FramingPlateScale] so the FOV reticle
/// is astrometrically co-registered with the survey background, the equipment
/// overlay, and the mosaic grid — they all derive on-screen pixels-per-degree
/// from the *same* plate scale.
class FramingFOVPainter extends CustomPainter {
  /// Radial gap, in logical pixels, between the top edge of the FOV rectangle
  /// and the center of the rotation handle.
  ///
  /// The handle circle is drawn this far above the rectangle's top edge so it
  /// sits clear of the corner markers. Exported as a public constant so the C6
  /// gesture ring imports the *same* value and its hit geometry matches where
  /// the handle is actually painted — there is no second, divergent copy of
  /// this number in the gesture code.
  static const double rotationHandleGap = 18.0;

  /// Radius, in logical pixels, of the rotation handle circle.
  ///
  /// The handle is drawn as a filled circle of this radius centered
  /// [rotationHandleGap] above the FOV rectangle's top edge. The C6 gesture
  /// hit-test ring is sized from this radius (see [rotationHitTolerance]) so a
  /// drag that visually lands on the handle is recognised as a rotation gesture.
  static const double rotationHandleRadius = 10.0;

  /// Slack, in logical pixels, added on either side of the handle radius when
  /// hit-testing the rotation gesture.
  ///
  /// The C6 gesture hit-tester treats a pointer-down within
  /// `rotationHandleRadius + rotationHitTolerance` of the handle center as
  /// grabbing the rotation handle. Centralizing this here keeps the touch
  /// target a fixed, documented size regardless of zoom (the handle itself is
  /// drawn at a zoom-independent radius), and guarantees the gesture ring and
  /// the painted handle never drift apart.
  static const double rotationHitTolerance = 10.0;

  final double fovWidth;
  final double fovHeight;
  final double zoom;

  /// Shared astrometric geometry supplying on-screen pixels-per-degree; the FOV
  /// rectangle is sized from [FramingPlateScale.pixelsPerDegree] so it stays
  /// pixel-aligned with the survey background and the other framing overlays.
  final FramingPlateScale plateScale;

  final SkotiqColors colors;
  final bool showDirections;

  FramingFOVPainter({
    required this.fovWidth,
    required this.fovHeight,
    required this.zoom,
    required this.plateScale,
    required this.colors,
    required this.showDirections,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // One shared astrometric scale: identical to the survey background and the
    // equipment / mosaic overlays. No hardcoded 60px/deg.
    final pixelsPerDegree = plateScale.pixelsPerDegree(size, zoom);
    final rectWidth = fovWidth * pixelsPerDegree;
    final rectHeight = fovHeight * pixelsPerDegree;

    final center = Offset(size.width / 2, size.height / 2);

    // Semi-transparent fill
    final fillPaint = Paint()
      ..color = colors.primary.withValues(alpha: SkotiqTokens.opacitySubtle)
      ..style = PaintingStyle.fill;

    // Border
    final borderPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final rect = Rect.fromCenter(
      center: center,
      width: rectWidth,
      height: rectHeight,
    );

    // Draw frame
    final rrect = RRect.fromRectAndRadius(
        rect, const Radius.circular(SkotiqTokens.radiusXs));
    canvas.drawRRect(rrect, fillPaint);
    canvas.drawRRect(rrect, borderPaint);

    // Draw corner markers
    _drawCorners(canvas, rect, borderPaint);

    // Draw rotation handle. The handle geometry is published via the static
    // constants above so the C6 gesture ring hit-tests exactly where the handle
    // is painted.
    final handlePaint = Paint()
      ..color = colors.primary
      ..style = PaintingStyle.fill;
    final handleY = center.dy - rectHeight / 2 - rotationHandleGap;
    canvas.drawCircle(
        Offset(center.dx, handleY), rotationHandleRadius, handlePaint);
    canvas.drawLine(
      Offset(center.dx, center.dy - rectHeight / 2),
      Offset(center.dx, handleY + rotationHandleRadius),
      borderPaint,
    );

    // Draw rotation icon
    final iconPainter = TextPainter(
      text: TextSpan(
        text: '↻',
        style: SkotiqTypography.labelSm
            .copyWith(color: colors.onPrimary, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    );
    iconPainter.layout();
    iconPainter.paint(
      canvas,
      Offset(
          center.dx - iconPainter.width / 2, handleY - iconPainter.height / 2),
    );

    // Draw cardinal directions
    if (showDirections) {
      _drawCardinalDirections(canvas, center, rectWidth, rectHeight);
    }

    // Draw FOV dimensions
    final fovText =
        '${fovWidth.toStringAsFixed(2)}° × ${fovHeight.toStringAsFixed(2)}°';
    final textPainter = TextPainter(
      text: TextSpan(
        text: fovText,
        style: SkotiqTypography.labelSm.copyWith(color: colors.primary),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // Draw text background scrim using the semantic overlay surface so the label
    // stays legible over arbitrary survey imagery across all themes.
    final textBg = Rect.fromCenter(
      center: Offset(center.dx, center.dy + rectHeight / 2 + 18),
      width: textPainter.width + 12,
      height: textPainter.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          textBg, const Radius.circular(SkotiqTokens.radiusXs)),
      Paint()
        ..color = colors.surfaceOverlay
            .withValues(alpha: SkotiqTokens.opacityHoverBorder),
    );
    textPainter.paint(
      canvas,
      Offset(
          center.dx - textPainter.width / 2, center.dy + rectHeight / 2 + 15),
    );
  }

  void _drawCorners(Canvas canvas, Rect rect, Paint paint) {
    final cornerLength = math.min(rect.width, rect.height) * 0.1;
    paint.strokeWidth = 3;

    // Top-left
    canvas.drawLine(
        Offset(rect.left, rect.top + cornerLength), rect.topLeft, paint);
    canvas.drawLine(
        rect.topLeft, Offset(rect.left + cornerLength, rect.top), paint);

    // Top-right
    canvas.drawLine(
        Offset(rect.right - cornerLength, rect.top), rect.topRight, paint);
    canvas.drawLine(
        rect.topRight, Offset(rect.right, rect.top + cornerLength), paint);

    // Bottom-right
    canvas.drawLine(Offset(rect.right, rect.bottom - cornerLength),
        rect.bottomRight, paint);
    canvas.drawLine(rect.bottomRight,
        Offset(rect.right - cornerLength, rect.bottom), paint);

    // Bottom-left
    canvas.drawLine(
        Offset(rect.left + cornerLength, rect.bottom), rect.bottomLeft, paint);
    canvas.drawLine(
        rect.bottomLeft, Offset(rect.left, rect.bottom - cornerLength), paint);
  }

  void _drawCardinalDirections(
      Canvas canvas, Offset center, double width, double height) {
    final style = SkotiqTypography.overline.copyWith(
      color:
          colors.textPrimary.withValues(alpha: SkotiqTokens.opacityMuted),
      fontWeight: FontWeight.w500,
    );

    final directions = ['N', 'E', 'S', 'W'];
    final positions = [
      Offset(center.dx, center.dy - height / 2 + 12),
      Offset(center.dx + width / 2 - 12, center.dy),
      Offset(center.dx, center.dy + height / 2 - 12),
      Offset(center.dx - width / 2 + 8, center.dy),
    ];

    for (var i = 0; i < 4; i++) {
      final textPainter = TextPainter(
        text: TextSpan(text: directions[i], style: style),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        positions[i] - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant FramingFOVPainter oldDelegate) {
    return fovWidth != oldDelegate.fovWidth ||
        fovHeight != oldDelegate.fovHeight ||
        zoom != oldDelegate.zoom ||
        plateScale != oldDelegate.plateScale ||
        colors != oldDelegate.colors ||
        showDirections != oldDelegate.showDirections;
  }
}

/// Draws the equipment FOV overlay when the preview FOV is larger than the
/// equipment FOV. This shows the user what their actual capture area will be.
///
/// Like [FramingFOVPainter] and [FramingMosaicGridPainter], the rectangle is
/// scaled from the shared [FramingPlateScale] — the *same* plate scale the
/// survey background is drawn at — so the capture area lines up to the pixel
/// with both the survey imagery and the FOV / mosaic overlays.
class FramingEquipmentFOVOverlayPainter extends CustomPainter {
  final double fovWidth;
  final double fovHeight;
  final double zoom;

  /// Shared astrometric geometry supplying on-screen pixels-per-degree. This
  /// replaces the painter's former `size.width / previewFov * zoom` scale, which
  /// was a third, divergent mapping. The equipment rectangle is now consistent
  /// with both the survey background and the FOV / mosaic painters.
  final FramingPlateScale plateScale;

  final SkotiqColors colors;
  final double opacity;
  final bool showDirections;

  FramingEquipmentFOVOverlayPainter({
    required this.fovWidth,
    required this.fovHeight,
    required this.zoom,
    required this.plateScale,
    required this.colors,
    required this.opacity,
    required this.showDirections,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Shared astrometric scale — consistent with the survey background AND the
    // FOV / mosaic painters.
    final pixelsPerDegree = plateScale.pixelsPerDegree(size, zoom);
    final rectWidth = fovWidth * pixelsPerDegree;
    final rectHeight = fovHeight * pixelsPerDegree;

    final center = Offset(size.width / 2, size.height / 2);

    // Semi-transparent fill for the equipment FOV area
    final fillPaint = Paint()
      ..color = colors.info
          .withValues(alpha: opacity * SkotiqTokens.opacityStrong)
      ..style = PaintingStyle.fill;

    // Border for the equipment FOV
    final borderPaint = Paint()
      ..color =
          colors.info.withValues(alpha: SkotiqTokens.opacityHoverBorder)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final rect = Rect.fromCenter(
      center: center,
      width: rectWidth,
      height: rectHeight,
    );

    // Draw scrim outside the equipment FOV using the semantic overlay surface so
    // the masked region dims survey imagery consistently across themes.
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(
      path,
      Paint()..color = colors.surfaceOverlay.withValues(alpha: opacity),
    );

    // Draw equipment FOV frame
    final rrect = RRect.fromRectAndRadius(
        rect, const Radius.circular(SkotiqTokens.radiusXs));
    canvas.drawRRect(rrect, fillPaint);
    canvas.drawRRect(rrect, borderPaint);

    // Draw corner brackets
    _drawCornerBrackets(canvas, rect, borderPaint);

    // Draw equipment FOV label
    final fovText =
        'Equipment FOV: ${fovWidth.toStringAsFixed(2)}° × ${fovHeight.toStringAsFixed(2)}°';
    final textPainter = TextPainter(
      text: TextSpan(
        text: fovText,
        style: SkotiqTypography.labelSm.copyWith(color: colors.info),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // Draw text background
    final textBg = Rect.fromCenter(
      center: Offset(center.dx, rect.top - 16),
      width: textPainter.width + 16,
      height: textPainter.height + 8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          textBg, const Radius.circular(SkotiqTokens.radiusXs)),
      Paint()
        ..color =
            colors.info.withValues(alpha: SkotiqTokens.opacityStatusFill),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          textBg, const Radius.circular(SkotiqTokens.radiusXs)),
      Paint()
        ..color = colors.info.withValues(alpha: SkotiqTokens.opacityHalf)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2,
          rect.top - textPainter.height / 2 - 16),
    );

    // Draw cardinal directions inside the equipment FOV
    if (showDirections) {
      _drawCardinalDirections(canvas, center, rectWidth, rectHeight);
    }
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, Paint paint) {
    final bracketLength = math.min(rect.width, rect.height) * 0.12;
    paint.strokeWidth = 3;

    // Top-left bracket
    canvas.drawLine(Offset(rect.left - 2, rect.top + bracketLength),
        Offset(rect.left - 2, rect.top - 2), paint);
    canvas.drawLine(Offset(rect.left - 2, rect.top - 2),
        Offset(rect.left + bracketLength, rect.top - 2), paint);

    // Top-right bracket
    canvas.drawLine(Offset(rect.right - bracketLength, rect.top - 2),
        Offset(rect.right + 2, rect.top - 2), paint);
    canvas.drawLine(Offset(rect.right + 2, rect.top - 2),
        Offset(rect.right + 2, rect.top + bracketLength), paint);

    // Bottom-right bracket
    canvas.drawLine(Offset(rect.right + 2, rect.bottom - bracketLength),
        Offset(rect.right + 2, rect.bottom + 2), paint);
    canvas.drawLine(Offset(rect.right + 2, rect.bottom + 2),
        Offset(rect.right - bracketLength, rect.bottom + 2), paint);

    // Bottom-left bracket
    canvas.drawLine(Offset(rect.left + bracketLength, rect.bottom + 2),
        Offset(rect.left - 2, rect.bottom + 2), paint);
    canvas.drawLine(Offset(rect.left - 2, rect.bottom + 2),
        Offset(rect.left - 2, rect.bottom - bracketLength), paint);
  }

  void _drawCardinalDirections(
      Canvas canvas, Offset center, double width, double height) {
    final style = SkotiqTypography.overline.copyWith(
      color: colors.info.withValues(alpha: SkotiqTokens.opacityMuted),
      fontWeight: FontWeight.w500,
    );

    final directions = ['N', 'E', 'S', 'W'];
    final positions = [
      Offset(center.dx, center.dy - height / 2 + 14),
      Offset(center.dx + width / 2 - 14, center.dy),
      Offset(center.dx, center.dy + height / 2 - 14),
      Offset(center.dx - width / 2 + 10, center.dy),
    ];

    for (var i = 0; i < 4; i++) {
      final textPainter = TextPainter(
        text: TextSpan(text: directions[i], style: style),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        positions[i] - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant FramingEquipmentFOVOverlayPainter oldDelegate) {
    return fovWidth != oldDelegate.fovWidth ||
        fovHeight != oldDelegate.fovHeight ||
        zoom != oldDelegate.zoom ||
        plateScale != oldDelegate.plateScale ||
        colors != oldDelegate.colors ||
        opacity != oldDelegate.opacity ||
        showDirections != oldDelegate.showDirections;
  }
}

/// Draws the mosaic panel grid: panel outlines, optional numbering, optional
/// sequence path, selection highlight, and a START marker on panel 1.
///
/// Panel dimensions are scaled from the shared [FramingPlateScale] so each
/// panel's on-screen size matches the equipment FOV rectangle and the survey
/// background exactly — the mosaic tiles cover precisely the sky the imagery
/// shows beneath them.
class FramingMosaicGridPainter extends CustomPainter {
  final FramingMosaicConfig config;
  final List<FramingMosaicPanel> panels;
  final double fovWidth;
  final double fovHeight;
  final double zoom;

  /// Shared astrometric geometry supplying on-screen pixels-per-degree; the
  /// panel grid is sized from [FramingPlateScale.pixelsPerDegree], the same
  /// scale used by the survey background and the FOV / equipment overlays.
  final FramingPlateScale plateScale;

  final SkotiqColors colors;
  final bool showPanelNumbers;
  final bool showSequencePath;
  final int selectedPanelIndex;

  FramingMosaicGridPainter({
    required this.config,
    required this.panels,
    required this.fovWidth,
    required this.fovHeight,
    required this.zoom,
    required this.plateScale,
    required this.colors,
    required this.showPanelNumbers,
    required this.showSequencePath,
    required this.selectedPanelIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Shared astrometric scale — identical to the survey background and the FOV
    // / equipment overlays. No hardcoded 60px/deg.
    final scale = plateScale.pixelsPerDegree(size, zoom);
    final panelWidth = fovWidth * scale;
    final panelHeight = fovHeight * scale;

    // Calculate step size accounting for overlap
    final overlapFactor = 1 - (config.overlapPercent / 100);
    final stepX = panelWidth * overlapFactor;
    final stepY = panelHeight * overlapFactor;

    // Calculate total mosaic extent
    final totalWidth = panelWidth + (config.columns - 1) * stepX;
    final totalHeight = panelHeight + (config.rows - 1) * stepY;

    // Starting offset (top-left corner of mosaic relative to center)
    final startX = center.dx - totalWidth / 2 + panelWidth / 2;
    final startY = center.dy - totalHeight / 2 + panelHeight / 2;

    // Draw mosaic outline
    final outlinePaint = Paint()
      ..color = colors.warning.withValues(alpha: SkotiqTokens.opacityHalf)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawRect(
      Rect.fromCenter(
        center: center,
        width: totalWidth,
        height: totalHeight,
      ),
      outlinePaint,
    );

    // Draw sequence path if enabled
    if (showSequencePath && panels.length > 1) {
      final pathPaint = Paint()
        ..color = colors.warning
            .withValues(alpha: SkotiqTokens.opacityBadgeBorder)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;

      final path = Path();
      bool first = true;

      for (final panel in panels) {
        final panelX = startX + panel.column * stepX;
        final panelY = startY + panel.row * stepY;

        if (first) {
          path.moveTo(panelX, panelY);
          first = false;
        } else {
          path.lineTo(panelX, panelY);
        }
      }

      canvas.drawPath(path, pathPaint);
    }

    // Draw individual panels
    for (int i = 0; i < panels.length; i++) {
      final panel = panels[i];
      final panelX = startX + panel.column * stepX;
      final panelY = startY + panel.row * stepY;
      final isSelected = i == selectedPanelIndex;

      // Panel rect
      final panelRect = Rect.fromCenter(
        center: Offset(panelX, panelY),
        width: panelWidth,
        height: panelHeight,
      );

      // Draw panel fill
      final fillPaint = Paint()
        ..color = isSelected
            ? colors.primary.withValues(alpha: SkotiqTokens.opacityMedium)
            : colors.warning.withValues(alpha: SkotiqTokens.opacityTint)
        ..style = PaintingStyle.fill;
      canvas.drawRect(panelRect, fillPaint);

      // Draw panel border
      final borderPaint = Paint()
        ..color = isSelected
            ? colors.primary
                .withValues(alpha: SkotiqTokens.opacityHoverBorder)
            : colors.warning
                .withValues(alpha: SkotiqTokens.opacityBadgeBorder)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2 : 1;
      canvas.drawRect(panelRect, borderPaint);

      // Draw panel number
      if (showPanelNumbers) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: '${panel.index + 1}',
            style: SkotiqTypography.label.copyWith(
              color: isSelected ? colors.primary : colors.warning,
              fontWeight: FontWeight.bold,
              fontSize:
                  SkotiqTypography.label.fontSize! * zoom.clamp(0.5, 2.0),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        textPainter.paint(
          canvas,
          Offset(
            panelX - textPainter.width / 2,
            panelY - textPainter.height / 2,
          ),
        );
      }

      // Draw crosshair on selected panel
      if (isSelected) {
        final crosshairPaint = Paint()
          ..color =
              colors.primary.withValues(alpha: SkotiqTokens.opacityMuted)
          ..strokeWidth = 1;

        canvas.drawLine(
          Offset(panelX - 10, panelY),
          Offset(panelX + 10, panelY),
          crosshairPaint,
        );
        canvas.drawLine(
          Offset(panelX, panelY - 10),
          Offset(panelX, panelY + 10),
          crosshairPaint,
        );
      }
    }

    // Draw start indicator
    if (panels.isNotEmpty) {
      final firstPanel = panels.first;
      final startX2 = startX + firstPanel.column * stepX;
      final startY2 = startY + firstPanel.row * stepY;

      final startPaint = Paint()
        ..color = colors.success
            .withValues(alpha: SkotiqTokens.opacityHoverBorder)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(
        Offset(startX2, startY2),
        6 * zoom.clamp(0.5, 1.5),
        startPaint,
      );

      final textPainter = TextPainter(
        text: TextSpan(
          text: 'START',
          style: SkotiqTypography.overline.copyWith(
            color: colors.success,
            fontWeight: FontWeight.bold,
            fontSize:
                SkotiqTypography.overline.fontSize! * zoom.clamp(0.7, 1.3),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(
          startX2 - textPainter.width / 2,
          startY2 + 10 * zoom.clamp(0.5, 1.5),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant FramingMosaicGridPainter oldDelegate) {
    return config.columns != oldDelegate.config.columns ||
        config.rows != oldDelegate.config.rows ||
        config.overlapPercent != oldDelegate.config.overlapPercent ||
        fovWidth != oldDelegate.fovWidth ||
        fovHeight != oldDelegate.fovHeight ||
        zoom != oldDelegate.zoom ||
        plateScale != oldDelegate.plateScale ||
        colors != oldDelegate.colors ||
        showPanelNumbers != oldDelegate.showPanelNumbers ||
        showSequencePath != oldDelegate.showSequencePath ||
        selectedPanelIndex != oldDelegate.selectedPanelIndex ||
        panels.length != oldDelegate.panels.length;
  }
}
