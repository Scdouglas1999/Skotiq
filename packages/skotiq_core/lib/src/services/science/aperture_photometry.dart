/// Fixed-aperture photometry on small cutouts of an uncompressed FITS image.
///
/// Differential photometry needs every star of a frame measured the same way.
/// The star detector sums each star inside its own footprint, which grows
/// with the star's brightness and the seeing, so a target and its
/// comparisons lose different fractions of their light from frame to frame.
/// Here every star gets the same circular aperture and a local sky annulus.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// One star measured in a circular aperture.
class ApertureFlux {
  const ApertureFlux({
    required this.flux,
    required this.backgroundSigma,
    required this.sky,
    required this.pixels,
  });

  /// Sky-subtracted flux in ADU.
  final double flux;

  /// 1-sigma flux error from the sky alone (pixel noise in the aperture and
  /// the error of the sky level), in ADU. The star's own photon noise is
  /// added by the caller, which knows the camera's e-/ADU.
  final double backgroundSigma;

  /// Sky level per pixel in ADU.
  final double sky;

  /// Aperture area in pixels.
  final double pixels;
}

/// Header facts needed to read pixels.
class _FitsLayout {
  const _FitsLayout({
    required this.width,
    required this.height,
    required this.bitpix,
    required this.bzero,
    required this.bscale,
    required this.dataOffset,
  });
  final int width;
  final int height;
  final int bitpix;
  final double bzero;
  final double bscale;
  final int dataOffset;

  int get bytesPerPixel => bitpix.abs() ~/ 8;
}

Future<_FitsLayout?> _readLayout(RandomAccessFile file) async {
  final values = <String, String>{};
  var offset = 0;
  final length = await file.length();
  while (offset + 2880 <= length) {
    await file.setPosition(offset);
    final block = await file.read(2880);
    offset += 2880;
    for (var i = 0; i < 2880; i += 80) {
      final card = String.fromCharCodes(block.sublist(i, i + 80));
      final key = card.substring(0, 8).trim();
      if (key == 'END') {
        int? intOf(String key) {
          final raw = values[key];
          return raw == null ? null : int.tryParse(raw);
        }

        // FITS defines BZERO = 0 and BSCALE = 1 when a header omits them.
        double scaling(String key, double fitsDefault) {
          final raw = values[key];
          final parsed = raw == null ? null : double.tryParse(raw);
          return parsed ?? fitsDefault;
        }

        final width = intOf('NAXIS1');
        final height = intOf('NAXIS2');
        final bitpix = intOf('BITPIX');
        final naxis = intOf('NAXIS');
        if (width == null || height == null || bitpix == null) return null;
        if (naxis != 2 || values.containsKey('ZIMAGE')) return null;
        if (![8, 16, 32, -32, -64].contains(bitpix)) return null;
        return _FitsLayout(
          width: width,
          height: height,
          bitpix: bitpix,
          bzero: scaling('BZERO', 0),
          bscale: scaling('BSCALE', 1),
          dataOffset: offset,
        );
      }
      if (card.length > 10 && card[8] == '=') {
        var value = card.substring(10);
        final slash = value.indexOf('/');
        if (slash >= 0 && !value.trimLeft().startsWith("'")) {
          value = value.substring(0, slash);
        }
        values[key] = value.trim();
      }
    }
  }
  return null;
}

double _sample(ByteData data, int index, _FitsLayout layout) {
  final o = index * layout.bytesPerPixel;
  final raw = switch (layout.bitpix) {
    8 => data.getUint8(o).toDouble(),
    16 => data.getInt16(o).toDouble(),
    32 => data.getInt32(o).toDouble(),
    -32 => data.getFloat32(o),
    _ => data.getFloat64(o),
  };
  return layout.bzero + layout.bscale * raw;
}

/// Measure every star at ([x], [y]) (0-based pixel centers, row 0 = first
/// FITS row, as the star detector reports them) in a circular aperture of
/// [radius] pixels, with the sky from an annulus [innerSky]..[outerSky].
///
/// Returns null when the file cannot be read as an uncompressed 2-D image;
/// an entry is null when its aperture or annulus leaves the image.
Future<List<ApertureFlux?>?> measureApertures(
  String path,
  List<({double x, double y})> stars, {
  required double radius,
  required double innerSky,
  required double outerSky,
}) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final layout = await _readLayout(file);
    if (layout == null) return null;
    final results = <ApertureFlux?>[];
    final half = outerSky.ceil() + 1;
    for (final star in stars) {
      final cx = star.x.round(), cy = star.y.round();
      final x0 = cx - half, x1 = cx + half;
      final y0 = cy - half, y1 = cy + half;
      if (x0 < 0 || y0 < 0 || x1 >= layout.width || y1 >= layout.height) {
        results.add(null);
        continue;
      }
      final w = x1 - x0 + 1;
      final cut = Float64List(w * (y1 - y0 + 1));
      for (var row = y0; row <= y1; row++) {
        await file.setPosition(
          layout.dataOffset + (row * layout.width + x0) * layout.bytesPerPixel,
        );
        final bytes = await file.read(w * layout.bytesPerPixel);
        final data = ByteData.sublistView(bytes);
        for (var i = 0; i < w; i++) {
          cut[(row - y0) * w + i] = _sample(data, i, layout);
        }
      }
      results.add(
        apertureFromCutout(
          cut,
          width: w,
          x: star.x - x0,
          y: star.y - y0,
          radius: radius,
          innerSky: innerSky,
          outerSky: outerSky,
        ),
      );
    }
    return results;
  } on Object {
    return null;
  } finally {
    await file?.close();
  }
}

/// Aperture sum on an in-memory cutout. Edge pixels are split into 5x5
/// sub-pixels so the aperture area does not jump as the star's center moves
/// by a fraction of a pixel between frames.
ApertureFlux? apertureFromCutout(
  Float64List cut, {
  required int width,
  required double x,
  required double y,
  required double radius,
  required double innerSky,
  required double outerSky,
}) {
  final height = cut.length ~/ width;
  final sky = <double>[];
  var sum = 0.0;
  var area = 0.0;
  for (var j = 0; j < height; j++) {
    for (var i = 0; i < width; i++) {
      final d = math.sqrt((i - x) * (i - x) + (j - y) * (j - y));
      final v = cut[j * width + i];
      if (d >= innerSky && d <= outerSky) sky.add(v);
      if (d > radius + 0.75) continue;
      double fraction;
      if (d < radius - 0.75) {
        fraction = 1;
      } else {
        var inside = 0;
        for (var sy = 0; sy < 5; sy++) {
          for (var sx = 0; sx < 5; sx++) {
            final px = i - 0.4 + 0.2 * sx - x;
            final py = j - 0.4 + 0.2 * sy - y;
            if (px * px + py * py <= radius * radius) inside++;
          }
        }
        fraction = inside / 25;
      }
      sum += fraction * v;
      area += fraction;
    }
  }
  if (sky.length < 20 || area <= 0) return null;
  // Sky: median after a 3-sigma clip, which drops stars in the annulus.
  var values = sky..sort();
  for (var k = 0; k < 3; k++) {
    final med = values[values.length ~/ 2];
    final dev = values.map((v) => (v - med).abs()).toList()..sort();
    final sigma = 1.4826 * dev[dev.length ~/ 2];
    if (sigma <= 0) break;
    final next = values.where((v) => (v - med).abs() <= 3 * sigma).toList();
    if (next.length == values.length || next.length < 20) break;
    values = next;
  }
  final skyLevel = values[values.length ~/ 2];
  final dev = values.map((v) => (v - skyLevel).abs()).toList()..sort();
  final skySigma = 1.4826 * dev[dev.length ~/ 2];
  final flux = sum - area * skyLevel;
  final variance =
      area * skySigma * skySigma +
      area * area * skySigma * skySigma * math.pi / (2 * values.length);
  return ApertureFlux(
    flux: flux,
    backgroundSigma: math.sqrt(variance),
    sky: skyLevel,
    pixels: area,
  );
}
