import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// Renders the C3 visible-tile selection to a PNG so the level-of-detail and
/// registration can be eyeballed and locked as a golden. This is the visual
/// proof that:
///
///   * [HipsTileSelection.selectNorder] picks a sensible order for the FOV,
///   * [HipsTileSelection.computeVisibleTiles] returns every tile touching the
///     canvas (no blank gutters), and
///   * each tile's subdivided mesh, forward-projected through C2, abuts its
///     neighbours seam-free (shared corners coincide on screen) and follows the
///     field rotation — so the FOV/mosaic overlay stays registered to the tiles.
///
/// The render draws, for the live framing projection (with pan + rotation), the
/// projected mesh of every visible tile (mesh lines), the FOV rectangle the
/// survey background occupies (same projection), and a center crosshair. Because
/// the projection is the exact one the framing background and overlays use, the
/// FOV rectangle and the tile mosaic register to the pixel.
///
/// Output:
///   * golden: `goldens/hips_tile_selection_<order>.png` (byte-locked)
///   * sample: repo-root `.hips_verify/hips_tile_selection_<order>.png`
void main() {
  test('C3 visible-tile selection renders registered and seam-free', () {
    // 4-degree-wide square survey cutout, 1200x900 canvas, panned + rotated to
    // exercise the full projection. DSS2-red-like 512-px order-9 survey.
    final props = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
''');

    const plateScale = FramingPlateScale(
      surveyFovWidthDeg: 4.0,
      surveyFovHeightDeg: 4.0,
      imagePixelWidth: 1200,
      imagePixelHeight: 1200,
    );
    const target = FramingTarget(
      name: 'NGC 7000',
      raHours: 20.971, // 314.57 deg, off the equator and off a face seam
      decDegrees: 44.52,
    );
    const canvas = Size(1200, 900);
    const zoom = 1.4;
    const pan = Offset(60, -40);
    const rotationDeg = 18.0;
    const imgW = 1200;
    const imgH = 900;

    final pxPerDeg = plateScale.pixelsPerDegree(canvas, zoom);
    final norder = HipsTileSelection.selectNorder(pxPerDeg, props);
    expect(norder, inInclusiveRange(props.hipsOrderMin, props.hipsOrder));

    final set = HipsTileSelection.computeVisibleTiles(
      plateScale,
      target,
      canvas,
      zoom,
      norder,
      props,
      subdivisions: 6,
      pan: pan,
      rotationDegrees: rotationDeg,
      surveyId: 'CDS/P/DSS2/red',
    );
    expect(set.tiles, isNotEmpty);

    final image = img.Image(width: imgW, height: imgH);
    img.fill(image, color: img.ColorRgb8(8, 12, 22));

    // Draw the FOV rectangle the survey background occupies, rotated about the
    // canvas center exactly as FramingSurveyImagePainter does. This visually
    // confirms the mosaic registers to the survey background rect.
    final fovRect = plateScale.drawRectFor(canvas, zoom, pan);
    _drawRotatedRect(
      image,
      fovRect,
      canvas,
      rotationDeg,
      img.ColorRgb8(60, 90, 130),
    );

    // Tint each tile by its LOD grandparent so the quadtree grouping is visible.
    final coarseOrder = (norder - 2).clamp(0, norder);

    var drawn = 0;
    for (final tile in set.tiles) {
      final group = tile.id.npix >> (2 * (norder - coarseOrder));
      final color = _seededRgb(group);
      final mesh = tile.mesh;
      final n = mesh.subdivisions;
      // Draw the mesh grid lines (rows + columns) so curvature + seams show.
      for (var row = 0; row <= n; row++) {
        for (var col = 0; col < n; col++) {
          _line(
            image,
            mesh.vertexAt(row, col).screen,
            mesh.vertexAt(row, col + 1).screen,
            color,
          );
        }
      }
      for (var col = 0; col <= n; col++) {
        for (var row = 0; row < n; row++) {
          _line(
            image,
            mesh.vertexAt(row, col).screen,
            mesh.vertexAt(row + 1, col).screen,
            color,
          );
        }
      }
      drawn++;
    }
    expect(
      drawn,
      greaterThan(4),
      reason: 'expected a populated mosaic, drew $drawn tiles',
    );

    // Center crosshair at the projected target.
    final c0 = set.projection.raDecToScreen(target.raHours, target.decDegrees);
    final cross = img.ColorRgb8(255, 80, 80);
    _line(image, Offset(c0.dx - 12, c0.dy), Offset(c0.dx + 12, c0.dy), cross);
    _line(image, Offset(c0.dx, c0.dy - 12), Offset(c0.dx, c0.dy + 12), cross);

    final png = img.encodePng(image);

    // Sample artifact at repo root for human inspection.
    final repoRoot = _repoRoot();
    final sampleDir = Directory('${repoRoot.path}/.hips_verify');
    sampleDir.createSync(recursive: true);
    final sample = File('${sampleDir.path}/hips_tile_selection_$norder.png');
    sample.writeAsBytesSync(png);
    // ignore: avoid_print
    print('HiPS C3 tile-selection sample written: ${sample.absolute.path}');

    // Golden lock: write on first run, byte-compare thereafter.
    final goldenDir = Directory('test/services/hips/goldens');
    goldenDir.createSync(recursive: true);
    final golden = File('${goldenDir.path}/hips_tile_selection_$norder.png');
    if (!golden.existsSync()) {
      golden.writeAsBytesSync(png);
      // ignore: avoid_print
      print('Golden created: ${golden.absolute.path}');
    } else {
      expect(
        png,
        golden.readAsBytesSync(),
        reason:
            'C3 tile-selection render drifted from golden; if '
            'intentional, delete ${golden.path} to regenerate.',
      );
    }
  });
}

img.Color _seededRgb(int seed) {
  final r = (seed * 2654435761) & 0x7fffffff;
  return img.ColorRgb8(
    90 + r % 140,
    90 + (r ~/ 140) % 140,
    110 + (r ~/ 19600) % 120,
  );
}

void _line(img.Image image, Offset a, Offset b, img.Color color) {
  img.drawLine(
    image,
    x1: a.dx.round(),
    y1: a.dy.round(),
    x2: b.dx.round(),
    y2: b.dy.round(),
    color: color,
  );
}

/// Draws [rect] rotated by [rotationDeg] about the canvas center, mirroring the
/// survey background painter's rotate-about-center composition.
void _drawRotatedRect(
  img.Image image,
  Rect rect,
  Size canvasSize,
  double rotationDeg,
  img.Color color,
) {
  final cx = canvasSize.width / 2.0;
  final cy = canvasSize.height / 2.0;
  final rad = rotationDeg * math.pi / 180.0;
  final cosR = math.cos(rad);
  final sinR = math.sin(rad);

  Offset rot(double x, double y) {
    final dx = x - cx;
    final dy = y - cy;
    return Offset(cx + dx * cosR - dy * sinR, cy + dx * sinR + dy * cosR);
  }

  final corners = <Offset>[
    rot(rect.left, rect.top),
    rot(rect.right, rect.top),
    rot(rect.right, rect.bottom),
    rot(rect.left, rect.bottom),
  ];
  for (var i = 0; i < 4; i++) {
    _line(image, corners[i], corners[(i + 1) % 4], color);
  }
}

/// Walks up to the repo root (directory holding `version.yaml`).
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/version.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.parent.parent;
}
