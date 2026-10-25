import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'darkroom_image.dart';

/// The share of a master's shorter side a channel tile shows when the
/// target's size on the sensor is not known.
const double darkroomDefaultTileSpan = .28;

/// How much sky around the target a tile keeps, as a multiple of its size.
const double _tileMargin = 1.4;

/// The square of a master a channel tile shows: [center] as a fraction of the
/// image width and height, and [span], the square's side as a fraction of
/// the image's shorter side.
@immutable
class DarkroomTileCrop {
  const DarkroomTileCrop({required this.center, required this.span});

  /// The whole image, centered.
  static const full = DarkroomTileCrop(center: Offset(.5, .5), span: 1);

  final Offset center;
  final double span;

  /// The crop for [master] of [target]: centered on the target where the
  /// master's WCS places it, else on the WCS reference pixel, else on the
  /// image center; sized so the target fills most of the tile when its size
  /// and the pixel scale are known, else to [darkroomDefaultTileSpan].
  factory DarkroomTileCrop.forMaster(
      IntegratedMaster master, DbTarget? target) {
    final w = master.width.toDouble(), h = master.height.toDouble();
    if (w <= 0 || h <= 0) return full;
    final wcs = _MasterWcs.of(master);
    var center = const Offset(.5, .5);
    if (wcs != null) {
      final pixel = target == null
          ? Offset(wcs.crpix1, wcs.crpix2)
          : wcs.skyToPixel(target.ra * 15, target.dec);
      if (pixel != null) {
        // FITS pixels are 1-based and centered on integers.
        final c = Offset((pixel.dx - .5) / w, (pixel.dy - .5) / h);
        if (c.dx >= 0 && c.dx <= 1 && c.dy >= 0 && c.dy <= 1) center = c;
      }
    }
    var span = darkroomDefaultTileSpan;
    final size = target?.sizeArcmin;
    final scale = wcs?.arcminPerPixel;
    if (size != null && size > 0 && scale != null && scale > 0) {
      span = (size * _tileMargin / scale / math.min(w, h)).clamp(.08, 1.0);
    }
    return DarkroomTileCrop(center: center, span: span);
  }

  @override
  bool operator ==(Object other) =>
      other is DarkroomTileCrop && other.center == center && other.span == span;

  @override
  int get hashCode => Object.hash(center, span);
}

/// A master's linear WCS in CD-matrix form.
class _MasterWcs {
  const _MasterWcs(
    this.crval1,
    this.crval2,
    this.crpix1,
    this.crpix2,
    this.cd11,
    this.cd12,
    this.cd21,
    this.cd22,
  );

  static _MasterWcs? of(IntegratedMaster m) {
    final values = [
      m.wcsCrval1,
      m.wcsCrval2,
      m.wcsCrpix1,
      m.wcsCrpix2,
      m.wcsCd1_1,
      m.wcsCd1_2,
      m.wcsCd2_1,
      m.wcsCd2_2,
    ];
    if (values.any((v) => v == null || !v.isFinite)) return null;
    final v = [for (final x in values) x!];
    return _MasterWcs(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
  }

  final double crval1, crval2, crpix1, crpix2, cd11, cd12, cd21, cd22;

  double get arcminPerPixel => math.sqrt(cd11 * cd11 + cd21 * cd21) * 60;

  /// The pixel (1-based) of the sky position [raDeg], [decDeg] through the
  /// gnomonic projection, or null when it is behind the tangent plane or the
  /// matrix is singular.
  Offset? skyToPixel(double raDeg, double decDeg) {
    const rad = math.pi / 180;
    final a = raDeg * rad, d = decDeg * rad;
    final a0 = crval1 * rad, d0 = crval2 * rad;
    final cosC = math.sin(d0) * math.sin(d) +
        math.cos(d0) * math.cos(d) * math.cos(a - a0);
    if (cosC <= 0) return null;
    final xi = math.cos(d) * math.sin(a - a0) / cosC / rad;
    final eta = (math.cos(d0) * math.sin(d) -
            math.sin(d0) * math.cos(d) * math.cos(a - a0)) /
        cosC /
        rad;
    final det = cd11 * cd22 - cd12 * cd21;
    if (det.abs() < 1e-18) return null;
    final dx = (cd22 * xi - cd12 * eta) / det;
    final dy = (-cd21 * xi + cd11 * eta) / det;
    return Offset(crpix1 + dx, crpix2 + dy);
  }
}

/// A square [crop] of a master's preview, filling its box.
class DarkroomCroppedPreview extends StatelessWidget {
  const DarkroomCroppedPreview({
    super.key,
    required this.path,
    required this.imageSize,
    required this.crop,
    this.placeholderIcon = SkotiqIcons.image,
  });

  final String? path;

  /// The master's size in pixels; the preview has the same aspect.
  final Size imageSize;
  final DarkroomTileCrop crop;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final side = math.min(box.maxWidth, box.maxHeight);
        final w = imageSize.width, h = imageSize.height;
        final file = path;
        if (w <= 0 ||
            h <= 0 ||
            !side.isFinite ||
            file == null ||
            !File(file).existsSync()) {
          return DarkroomPreviewImage(
            path: path,
            placeholderIcon: placeholderIcon,
          );
        }
        final short = math.min(w, h);
        final cropPx = short * crop.span;
        final k = side / cropPx;
        final drawnW = w * k, drawnH = h * k;
        // Keep the square inside the image.
        final left = (crop.center.dx * w - cropPx / 2)
            .clamp(0.0, math.max(0.0, w - cropPx));
        final top = (crop.center.dy * h - cropPx / 2)
            .clamp(0.0, math.max(0.0, h - cropPx));
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.translate(
              offset: Offset(-left * k, -top * k),
              child: SizedBox(
                width: drawnW,
                height: drawnH,
                child: DarkroomPreviewImage(
                  path: path,
                  fit: BoxFit.fill,
                  decodeWidth: (drawnW * dpr).round().clamp(64, 4096),
                  placeholderIcon: placeholderIcon,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
