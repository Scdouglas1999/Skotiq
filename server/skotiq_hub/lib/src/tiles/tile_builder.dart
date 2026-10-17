import 'dart:math' as math;
import 'dart:typed_data';

import 'tile_codec.dart';

/// Constructs in-memory [TileAccumulator]s. Used by the hub to seed an empty
/// base tile for a brand-new tile id, and by tests to synthesize contributor
/// deltas without the full Rust fold pipeline. The geometry constants are the
/// atlas defaults: order 9, 1024² tiles.
class TileBuilder {
  /// Default HEALPix order for atlas tiles. Matches
  /// `sky_atlas.rs::ATLAS_HEALPIX_ORDER`.
  static const int atlasHealpixOrder = 9;

  /// Per-tile raster edge in pixels. Matches `sky_atlas.rs::TILE_PIXELS`.
  static const int tilePixels = 1024;

  /// An empty accumulator for [tileId] at [order] with [channels] channels and a
  /// canonical tile WCS. All six running vectors are zeroed. Used as the merge
  /// base when the hub has never seen a tile before.
  static TileAccumulator empty({
    required int tileId,
    required int order,
    int channels = 1,
    int width = tilePixels,
    int height = tilePixels,
  }) {
    final slots = width * height * channels;
    final center = tileCenter(tileId, order);
    final header = <String, Object?>{
      'tile_id': tileId,
      'order': order,
      'width': width,
      'height': height,
      'channels': channels,
      'wcs': _canonicalTileWcs(center.$1, center.$2, width, height, order),
      'norm_reference': <String, Object?>{
        'background': List<double>.filled(channels, 0.0),
        'scale': List<double>.filled(channels, 1.0),
      },
      'mode': <String, Object?>{
        'RunningWeightedMean': <String, Object?>{'clip': null},
      },
      'provenance': <String, Object?>{
        'total_frames': 0,
        'total_integration_seconds': 0.0,
        'contributors': <String>[],
        'folds': <Object?>[],
      },
      'slot_count': slots,
    };
    return TileAccumulator(
      version: tileStateVersion,
      header: header,
      sumW: Float64List(slots),
      sumW2: Float64List(slots),
      sumWx: Float64List(slots),
      sumWx2: Float64List(slots),
      coverage: Uint32List(slots),
      rejected: Uint32List(slots),
    );
  }

  /// A synthetic single-contributor delta: every covered pixel sees [frames]
  /// samples of constant value [value] at unit weight. This produces a valid
  /// `.nst` whose finalized mean is exactly [value] and whose additivity the
  /// hub's fusion test relies on. Not used in production folds (the client folds
  /// real frames in Rust); it exists so tests can assert the server-side merge
  /// equals a local co-add without the imaging crate.
  static TileAccumulator synthetic({
    required int tileId,
    required int order,
    required double value,
    int frames = 1,
    double weightPerFrame = 1.0,
    double exposureSec = 300.0,
    int channels = 1,
    int width = tilePixels,
    int height = tilePixels,
    String contributor = '',
    String label = 'synthetic',
  }) {
    final tile = empty(
      tileId: tileId,
      order: order,
      channels: channels,
      width: width,
      height: height,
    );
    final totalWeight = weightPerFrame * frames;
    for (var i = 0; i < tile.slotCount; i++) {
      tile.sumW[i] = totalWeight;
      tile.sumW2[i] = weightPerFrame * weightPerFrame * frames;
      tile.sumWx[i] = totalWeight * value;
      tile.sumWx2[i] = totalWeight * value * value;
      tile.coverage[i] = frames;
    }
    final prov = tile.header['provenance']! as Map<String, Object?>;
    prov['total_frames'] = frames;
    prov['total_integration_seconds'] = exposureSec * frames;
    prov['contributors'] = <String>[contributor];
    prov['folds'] = <Object?>[
      <String, Object?>{
        'frames_added': frames,
        'weight_added': totalWeight,
        'integration_seconds_added': exposureSec * frames,
        'rejected': 0,
        'label': label,
        'contributor': contributor,
      },
    ];
    return tile;
  }

  /// HEALPix NESTED tile centre as (raDeg, decDeg). Deterministic from id +
  /// order, matching the geometry the keystone derives in `tile_center`.
  static (double, double) tileCenter(int tileId, int order) {
    final nside = 1 << order;
    final (z, phi) = _nestPix2ang(nside, tileId);
    final decDeg = math.asin(z) * 180.0 / math.pi;
    var raDeg = phi * 180.0 / math.pi;
    raDeg %= 360.0;
    if (raDeg < 0) raDeg += 360.0;
    return (raDeg, decDeg);
  }

  static Map<String, Object?> _canonicalTileWcs(
    double centerRa,
    double centerDec,
    int width,
    int height,
    int order,
  ) {
    // Fixed isotropic scale so TILE_PIXELS spans one HEALPix tile plus margin.
    // 12 * nside^2 tiles cover the sphere; a tile's angular edge ~ this scale.
    final nside = 1 << order;
    final tileEdgeDeg = math.sqrt(41252.96 / (12.0 * nside * nside));
    final marginFactor = 1.1;
    final scaleDegPerPx = tileEdgeDeg * marginFactor / width;
    final scaleDeg = scaleDegPerPx;
    return <String, Object?>{
      'crval1': centerRa,
      'crval2': centerDec,
      'crpix1': width / 2.0 + 0.5,
      'crpix2': height / 2.0 + 0.5,
      'cd1_1': -scaleDeg,
      'cd1_2': 0.0,
      'cd2_1': 0.0,
      'cd2_2': scaleDeg,
      'a_order': 0,
      'b_order': 0,
      'a_coeffs': <double>[],
      'b_coeffs': <double>[],
      'ap_order': 0,
      'bp_order': 0,
      'ap_coeffs': <double>[],
      'bp_coeffs': <double>[],
    };
  }

  /// HEALPix NESTED pixel → (z = sin(dec), phi = ra in radians) at [nside].
  /// Standard NESTED decode (Gorski et al. 2005).
  static (double, double) _nestPix2ang(int nside, int pix) {
    final npface = nside * nside;
    final faceNum = pix ~/ npface;
    final ipf = pix % npface;
    final (ix, iy) = _decodeInterleave(ipf);

    final jrt = ix + iy; // in {0, 2*(nside-1)}
    final jpt = ix - iy; // in {-(nside-1), nside-1}

    final jr = _jrll[faceNum] * nside - jrt - 1;
    var nr = nside;
    double z;
    int kshift;
    if (jr < nside) {
      nr = jr;
      z = 1.0 - nr * nr / (3.0 * nside * nside);
      kshift = 0;
    } else if (jr > 3 * nside) {
      nr = 4 * nside - jr;
      z = nr * nr / (3.0 * nside * nside) - 1.0;
      kshift = 0;
    } else {
      nr = nside;
      z = (2 * nside - jr) * 2.0 / (3.0 * nside);
      kshift = (jr - nside) & 1;
    }

    var jp = (_jpll[faceNum] * nr + jpt + 1 + kshift) ~/ 2;
    if (jp > 4 * nside) jp -= 4 * nside;
    if (jp < 1) jp += 4 * nside;

    final phi = (jp - (kshift + 1) * 0.5) * (math.pi / 2.0 / nr);
    return (z, phi);
  }

  /// Inverse of the bit-interleave used by the NESTED scheme: split [ipf] into
  /// its even-bit (x) and odd-bit (y) coordinates.
  static (int, int) _decodeInterleave(int ipf) {
    var ix = 0;
    var iy = 0;
    var bit = 0;
    var v = ipf;
    while (v > 0) {
      ix |= (v & 1) << bit;
      v >>= 1;
      iy |= (v & 1) << bit;
      v >>= 1;
      bit++;
    }
    return (ix, iy);
  }

  static const List<int> _jrll = <int>[2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4];
  static const List<int> _jpll = <int>[1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7];
}
