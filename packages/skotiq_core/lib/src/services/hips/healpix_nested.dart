// HEALPix NESTED-scheme spherical-pixelization math, pure Dart.
//
// This module is the geometric foundation of the Flutter-side GPU HiPS
// framing-tile layer. It converts between sky coordinates and HiPS tile
// indices and back, enumerates the visible tile set for a field of view,
// produces cell-corner sky points for mesh warping, and walks the quadtree
// of tile parents/children for level-of-detail selection.
//
// References (this implementation is verified against the published
// algorithms, not transliterated from any GPL HEALPix source):
//   * Górski, Hivon, Banday, Wandelt, Hansen, Reinecke, Bartelmann,
//     "HEALPix: A Framework for High-Resolution Discretization and Fast
//     Analysis of Data Distributed on the Sphere", ApJ 622:759-771, 2005.
//   * IVOA "HiPS - Hierarchical Progressive Survey" Recommendation 1.0
//     (2017-05-19), §4.1 "HEALPix" and §A "HEALPix NESTED tiling", which
//     fixes the NESTED scheme, `Nside = 2^Norder`, and the
//     12·Nside² pixel count used to address HiPS tiles.
//
// Conventions used throughout:
//   * NESTED numbering only (HiPS tiles are always NESTED). RING is not
//     implemented because HiPS never uses it.
//   * `Nside = 2^order` where `order` (HiPS "Norder") is in [0, 29]. The
//     upper bound keeps `12 * Nside^2` and the bit interleaving inside the
//     53-bit exact-integer range of a Dart `double`/`int` so pixel indices
//     never silently lose precision. order 29 already corresponds to a
//     pixel scale far finer than any real survey, so this is not a
//     practical limitation.
//   * Angles for the public sky API are RA/Dec in *degrees* (the unit the
//     framing render path uses). Internally the math runs in HEALPix's
//     native (z, phi) cylindrical form, with `z = sin(latitude)` and
//     `phi` the azimuth in radians. RA maps directly onto `phi`.
//   * Vectors returned by [pix2vec]/[boundaries] are unit Cartesian
//     vectors in the equatorial frame: +x toward RA=0/Dec=0, +y toward
//     RA=90°/Dec=0, +z toward the north celestial pole.
//
// There is deliberately no I/O and no Flutter dependency here: this file is
// pure spherical geometry so it can be unit-tested in isolation and reused
// by both the tile-streaming service and any future native consumer.

import 'dart:math' as math;

/// Every public entry point validates its inputs and throws this rather than
/// clamping or returning a bogus pixel, so an out-of-range order, pixel index
/// or coordinate cannot become a silently wrong tile.
class HealpixArgumentError extends ArgumentError {
  /// Creates an argument error for a HEALPix routine.
  HealpixArgumentError(super.message);
}

/// A face index (0..11) paired with fractional intra-face coordinates.
///
/// HEALPix tiles the sphere with 12 equal-area base faces. Within a face,
/// [x] and [y] run along the two diagonal directions of the face's diamond.
/// For the *integer* form used by pixel addressing, `x, y ∈ [0, Nside)`; for
/// the *fractional* form used by [HealpixNested.xyfToAng] and corner
/// generation, `x, y ∈ [0, Nside]` (the upper edge is inclusive so the
/// far corner of the last cell is representable).
class HealpixXyf {
  /// Coordinate along the face's first diagonal axis.
  final double x;

  /// Coordinate along the face's second diagonal axis.
  final double y;

  /// Base-face index, 0..11. Faces 0-3 are the north polar caps, 4-7 the
  /// equatorial belt, 8-11 the south polar caps.
  final int face;

  /// Creates a face/intra-face coordinate triple.
  const HealpixXyf(this.x, this.y, this.face);

  @override
  String toString() => 'HealpixXyf(x: $x, y: $y, face: $face)';

  @override
  bool operator ==(Object other) =>
      other is HealpixXyf && other.x == x && other.y == y && other.face == face;

  @override
  int get hashCode => Object.hash(x, y, face);
}

/// A sky direction expressed as HEALPix native `(theta, phi)`.
///
/// [theta] is the colatitude in radians measured from the north pole
/// (0 at +Dec 90°, π at -Dec 90°); [phi] is the azimuth in radians
/// (equal to RA in radians, wrapped to `[0, 2π)`). This is the form
/// HEALPix's own equations use; helpers convert to/from RA/Dec degrees.
class HealpixAngle {
  /// Colatitude in radians from the north pole, `[0, π]`.
  final double theta;

  /// Azimuth in radians, `[0, 2π)`. Equal to right ascension in radians.
  final double phi;

  /// Creates a `(theta, phi)` sky direction.
  const HealpixAngle(this.theta, this.phi);

  /// Right ascension in degrees, `[0, 360)`.
  double get raDeg => phi * 180.0 / math.pi;

  /// Declination in degrees, `[-90, 90]`.
  double get decDeg => 90.0 - theta * 180.0 / math.pi;

  @override
  String toString() => 'HealpixAngle(theta: $theta, phi: $phi)';

  @override
  bool operator ==(Object other) =>
      other is HealpixAngle && other.theta == theta && other.phi == phi;

  @override
  int get hashCode => Object.hash(theta, phi);
}

/// A unit Cartesian vector in the equatorial frame.
class Vector3 {
  /// X component (toward RA=0, Dec=0).
  final double x;

  /// Y component (toward RA=90°, Dec=0).
  final double y;

  /// Z component (toward the north celestial pole).
  final double z;

  /// Creates a 3-vector. Inputs are not auto-normalized; the HEALPix
  /// routines that build these guarantee unit length.
  const Vector3(this.x, this.y, this.z);

  /// Euclidean length.
  double get length => math.sqrt(x * x + y * y + z * z);

  /// Dot product with [o].
  double dot(Vector3 o) => x * o.x + y * o.y + z * o.z;

  @override
  String toString() =>
      'Vector3(${x.toStringAsFixed(6)}, ${y.toStringAsFixed(6)}, '
      '${z.toStringAsFixed(6)})';

  @override
  bool operator ==(Object other) =>
      other is Vector3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

/// Pure-Dart HEALPix math in the NESTED scheme, parameterized by HiPS order.
///
/// One instance is bound to a single HiPS `Norder` (`Nside = 2^order`). The
/// quadtree helpers ([parent], [children], [childAtOrder]) cross orders, so
/// callers building a level-of-detail pyramid will hold one instance per
/// order they render (instances are cheap and immutable).
class HealpixNested {
  /// Maximum supported order. At order 29, `Nside = 2^29` and the largest
  /// pixel index `12*Nside^2 - 1 ≈ 3.46e18` plus the bit-interleaving
  /// temporaries stay inside the 2^63-1 range of a Dart 64-bit `int` (and,
  /// critically, the pieces that must round-trip through `double` stay
  /// inside 2^53). Going higher would risk silent precision loss, which is
  /// exactly the kind of "silent wrong answer" this codebase forbids.
  static const int maxOrder = 29;

  /// HiPS Norder (resolution level) this instance addresses.
  final int order;

  /// `Nside = 2^order`. Side length of a base face in pixels.
  final int nside;

  /// Total pixel count `12 * Nside^2`.
  final int npix;

  /// `1 / Nside`, precomputed for the hot fractional-coordinate paths.
  final double _invNside;

  HealpixNested._(this.order, this.nside, this.npix, this._invNside);

  /// Builds a HEALPix helper for HiPS [order] (Norder), `0 <= order <= 29`.
  factory HealpixNested(int order) {
    if (order < 0 || order > maxOrder) {
      throw HealpixArgumentError(
        'HEALPix order must be in [0, $maxOrder], got $order',
      );
    }
    final ns = 1 << order;
    final np = 12 * ns * ns;
    return HealpixNested._(order, ns, np, 1.0 / ns);
  }

  /// Builds a helper directly from an [nside] that must be a power of two.
  ///
  /// Provided for callers that carry an `Nside` rather than a HiPS order;
  /// it derives the order and validates the power-of-two constraint that
  /// the NESTED scheme requires.
  factory HealpixNested.fromNside(int nside) {
    if (nside < 1 || (nside & (nside - 1)) != 0) {
      throw HealpixArgumentError(
        'Nside must be a positive power of two, got $nside',
      );
    }
    final order = _log2(nside);
    return HealpixNested(order);
  }

  // Base-face geometry tables (Górski et al. 2005, Fig. 4)

  /// For each of the 12 faces, the integer multiple of `Nside` that locates
  /// the face's reference column in the (ix, iy) raster used by the
  /// xyf→ring conversion. Faces 0-3: north caps, 4-7: equator, 8-11: south.
  static const List<int> _jrll = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4];

  /// Companion to [_jrll]: the face's reference offset in the longitudinal
  /// direction, in units of the equatorial spacing.
  static const List<int> _jpll = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7];

  // Forward: sky -> pixel

  /// Converts a sky direction (RA/Dec in degrees) to a NESTED pixel index.
  ///
  /// [raDeg] is wrapped into `[0, 360)`; [decDeg] must lie in `[-90, 90]`.
  int ang2pixNest(double raDeg, double decDeg) {
    if (decDeg < -90.0 || decDeg > 90.0) {
      throw HealpixArgumentError(
        'Declination must be in [-90, 90], got $decDeg',
      );
    }
    final phi = _wrapTwoPi(raDeg * math.pi / 180.0);
    final z = math.sin(decDeg * math.pi / 180.0);
    return _zphiToNest(z, phi);
  }

  /// Converts native `(theta, phi)` radians to a NESTED pixel index.
  int angToPixNest(HealpixAngle a) {
    if (a.theta < 0.0 || a.theta > math.pi) {
      throw HealpixArgumentError('theta must be in [0, pi], got ${a.theta}');
    }
    final z = math.cos(a.theta);
    return _zphiToNest(z, _wrapTwoPi(a.phi));
  }

  /// Converts a unit vector to a NESTED pixel index.
  int vecToPixNest(Vector3 v) {
    final len = v.length;
    if (len == 0.0) {
      throw HealpixArgumentError('Cannot convert zero vector to a pixel');
    }
    final z = v.z / len;
    final phi = _wrapTwoPi(math.atan2(v.y, v.x));
    return _zphiToNest(z, phi);
  }

  // Inverse: pixel -> sky

  /// Converts a NESTED pixel index to its center sky direction (RA/Dec deg).
  HealpixAngle pix2ang(int ipix) {
    _checkPix(ipix);
    final xyf = nestToXyf(ipix);
    // Pixel centers sit at the half-integer lattice point.
    return xyfToAng(HealpixXyf(xyf.x + 0.5, xyf.y + 0.5, xyf.face));
  }

  /// Convenience wrapper returning the pixel center as `(raDeg, decDeg)`.
  ({double raDeg, double decDeg}) pix2RaDec(int ipix) {
    final a = pix2ang(ipix);
    return (raDeg: a.raDeg, decDeg: a.decDeg);
  }

  /// Converts a NESTED pixel index to its center unit vector.
  Vector3 pix2vec(int ipix) => angToVec(pix2ang(ipix));

  // Face decomposition

  /// Decomposes a NESTED pixel index into integer `(x, y, face)`.
  ///
  /// The low `2*order` bits of [ipix] are the bit-interleaved intra-face
  /// position (even bits → x, odd bits → y); the high bits select the face.
  HealpixXyf nestToXyf(int ipix) {
    _checkPix(ipix);
    final pixPerFace = nside * nside;
    final face = ipix ~/ pixPerFace;
    final inFace = ipix - face * pixPerFace;
    final ix = _deinterleaveEven(inFace);
    final iy = _deinterleaveOdd(inFace);
    return HealpixXyf(ix.toDouble(), iy.toDouble(), face);
  }

  /// Composes integer `(x, y, face)` back into a NESTED pixel index.
  ///
  /// [ix] and [iy] must be in `[0, Nside)` and [face] in `[0, 12)`; the
  /// fractional parts of the [HealpixXyf] are truncated to the containing
  /// cell, which is the correct behavior for "which pixel contains this
  /// fractional point".
  int xyfToNest(HealpixXyf xyf) {
    if (xyf.face < 0 || xyf.face > 11) {
      throw HealpixArgumentError('face must be in [0, 12), got ${xyf.face}');
    }
    final ix = xyf.x.floor();
    final iy = xyf.y.floor();
    if (ix < 0 || ix >= nside || iy < 0 || iy >= nside) {
      throw HealpixArgumentError(
        'Intra-face (x, y) must be in [0, $nside), got ($ix, $iy)',
      );
    }
    return xyf.face * nside * nside + _interleave(ix, iy);
  }

  // Fractional intra-face <-> sky

  /// Maps a fractional intra-face coordinate to a sky direction.
  ///
  /// Accepts `x, y ∈ [0, Nside]` (upper edge inclusive) so cell corners on
  /// the far edge of a face are representable. This is the workhorse used by
  /// [boundaries] for mesh-warping the survey imagery onto the sphere.
  HealpixAngle xyfToAng(HealpixXyf xyf) {
    final face = xyf.face;
    if (face < 0 || face > 11) {
      throw HealpixArgumentError('face must be in [0, 12), got $face');
    }
    if (xyf.x < 0.0 || xyf.x > nside || xyf.y < 0.0 || xyf.y > nside) {
      throw HealpixArgumentError(
        'Fractional (x, y) must be in [0, $nside], got (${xyf.x}, ${xyf.y})',
      );
    }

    // Normalized face coordinates in [0, 1].
    final fx = xyf.x * _invNside;
    final fy = xyf.y * _invNside;

    // Canonical HEALPix `xyf2loc` (Healpix_Base): `jr` is the continuous
    // ring coordinate (range [_jrll-2, _jrll]); `nr` is the half-width of
    // the ring in cap units (1 in the equatorial belt, shrinking to 0 at a
    // pole). `z = cos(theta)`; the longitude `tmp` combines the face's
    // [_jpll] base offset (scaled by `nr`) with the in-face diagonal
    // `fx - fy`. This is the exact inverse of [_zphiToXyf].
    final jr = _jrll[face] - fx - fy;
    final double z;
    final double nr;

    if (jr < 1.0) {
      // North polar cap.
      nr = jr;
      z = 1.0 - nr * nr / 3.0;
    } else if (jr > 3.0) {
      // South polar cap (mirror of the north).
      nr = 4.0 - jr;
      z = nr * nr / 3.0 - 1.0;
    } else {
      // Equatorial belt.
      nr = 1.0;
      z = (2.0 - jr) * 2.0 / 3.0;
    }

    var tmp = _jpll[face] * nr + fx - fy;
    if (tmp < 0.0) tmp += 8.0;
    if (tmp >= 8.0) tmp -= 8.0;
    final phi = (nr < 1e-15) ? 0.0 : _wrapTwoPi((math.pi / 4.0) * tmp / nr);

    final theta = math.acos(z.clamp(-1.0, 1.0));
    return HealpixAngle(theta, phi);
  }

  /// Maps a sky direction to fractional intra-face `(x, y, face)`.
  ///
  /// Inverse of [xyfToAng]; flooring the returned `(x, y)` and calling
  /// [xyfToNest] yields the containing pixel, while the fractional part
  /// gives sub-pixel position for texture sampling. [raDeg] is wrapped to
  /// `[0, 360)`; [decDeg] must be in `[-90, 90]`.
  HealpixXyf angToXyf(double raDeg, double decDeg) {
    if (decDeg < -90.0 || decDeg > 90.0) {
      throw HealpixArgumentError(
        'Declination must be in [-90, 90], got $decDeg',
      );
    }
    final phi = _wrapTwoPi(raDeg * math.pi / 180.0);
    final z = math.sin(decDeg * math.pi / 180.0);
    return _zphiToXyf(z, phi);
  }

  // Cell boundary (corner) generation

  /// Returns the four corner sky directions of a NESTED pixel, ordered
  /// counter-clockwise as seen from outside the sphere:
  /// `[south, east, north, west]` corner.
  ///
  /// These corners drive the textured-quad / mesh warp that maps a square
  /// HiPS tile image onto its (curved) sky footprint in the framing canvas.
  /// Because tiles share corners with their neighbors exactly, building the
  /// mesh from these points yields seam-free mosaicing.
  List<HealpixAngle> boundaries(int ipix) {
    _checkPix(ipix);
    final xyf = nestToXyf(ipix);
    final ix = xyf.x;
    final iy = xyf.y;
    final f = xyf.face;
    // The diamond's four corners in fractional face coordinates.
    return [
      xyfToAng(HealpixXyf(ix, iy, f)), // south
      xyfToAng(HealpixXyf(ix + 1, iy, f)), // east
      xyfToAng(HealpixXyf(ix + 1, iy + 1, f)), // north
      xyfToAng(HealpixXyf(ix, iy + 1, f)), // west
    ];
  }

  /// Like [boundaries] but returns unit Cartesian vectors, convenient for
  /// feeding a GPU vertex buffer directly.
  List<Vector3> boundaryVectors(int ipix) =>
      boundaries(ipix).map(angToVec).toList(growable: false);

  // Neighbours

  /// Compass directions of the eight [neighboursNest] slots, in result
  /// order. Index 0 = West, then NW, N, NE, E, SE, S, SW (counter-clockwise
  /// from West). This is the canonical HEALPix `neighbors` ordering.
  static const List<String> neighbourDirections = [
    'W',
    'NW',
    'N',
    'NE',
    'E',
    'SE',
    'S',
    'SW',
  ];

  /// In-face step in x for each of the eight directions, matching
  /// [neighbourDirections].
  static const List<int> _xOffset = [-1, -1, 0, 1, 1, 1, 0, -1];

  /// In-face step in y for each of the eight directions, matching
  /// [neighbourDirections].
  static const List<int> _yOffset = [0, 1, 1, 1, 0, -1, -1, -1];

  /// Face-transition table from the HEALPix C++ `Healpix_Base::neighbors`.
  /// Row `r` selects the rule for crossing a face edge: rows 0-3 handle the
  /// north/east/south/west edges, row 4 stays on-face, rows 5-8 the four
  /// diagonal corners. Column is the source face (0..11). `-1` marks the
  /// non-existent neighbour at a base-face corner.
  static const List<List<int>> _faceArray = [
    [8, 9, 10, 11, -1, -1, -1, -1, 10, 11, 8, 9], // S
    [5, 6, 7, 4, 8, 9, 10, 11, 9, 10, 11, 8], // SE
    [-1, -1, -1, -1, 5, 6, 7, 4, -1, -1, -1, -1], // E
    [4, 5, 6, 7, 11, 8, 9, 10, 11, 8, 9, 10], // SW
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], // center
    [1, 2, 3, 0, 0, 1, 2, 3, 5, 6, 7, 4], // NE
    [-1, -1, -1, -1, 7, 4, 5, 6, -1, -1, -1, -1], // W
    [3, 0, 1, 2, 3, 0, 1, 2, 4, 5, 6, 7], // NW
    [2, 3, 0, 1, -1, -1, -1, -1, 0, 1, 2, 3], // N
  ];

  /// Companion to [_faceArray]: when nonzero, the (x, y) coordinates must be
  /// transformed as the edge is crossed. Bit 1 (value 1) swaps x<->y; the
  /// sign of the value flags whether x and/or y must be reflected to
  /// `Nside-1-coord`. This is the HEALPix `swap_array`, flattened into the
  /// three latitude regions (cap/belt/cap) the source pixel can be in.
  static const List<List<int>> _swapArray = [
    [0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3], // S
    [0, 0, 0, 0, 0, 0, 0, 0, 6, 6, 6, 6], // SE
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // E
    [0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 5, 5], // SW
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // center
    [5, 5, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0], // NE
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // W
    [6, 6, 6, 6, 0, 0, 0, 0, 0, 0, 0, 0], // NW
    [3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0], // N
  ];

  /// Returns the (up to 8) NESTED indices of the pixels adjacent to [ipix],
  /// ordered by [neighbourDirections] (`[W, NW, N, NE, E, SE, S, SW]`).
  ///
  /// At the eight base-face "diagonal" corners a pixel has only seven
  /// neighbours; the missing slot is reported as `-1`. Callers enumerating
  /// a visible set should skip `-1` entries. This is a direct port of the
  /// HEALPix C++ `Healpix_Base::neighbors` NESTED algorithm, including the
  /// face-transition `_faceArray`/`_swapArray` tables, so it is exact across
  /// every face seam and pole.
  List<int> neighboursNest(int ipix) {
    _checkPix(ipix);
    final xyf = nestToXyf(ipix);
    final ix = xyf.x.toInt();
    final iy = xyf.y.toInt();
    final faceNum = xyf.face;
    final nsm1 = nside - 1;

    final result = List<int>.filled(8, -1);
    final base = faceNum * nside * nside;

    // Fast interior path: not on any face edge -> all eight neighbours are
    // in the same face, no transition table needed.
    if (ix > 0 && ix < nsm1 && iy > 0 && iy < nsm1) {
      for (var m = 0; m < 8; m++) {
        result[m] = base + _interleave(ix + _xOffset[m], iy + _yOffset[m]);
      }
      return result;
    }

    for (var i = 0; i < 8; i++) {
      var x = ix + _xOffset[i];
      var y = iy + _yOffset[i];
      var nbnum = 4; // default: stay on this face (center row)

      if (x < 0) {
        x += nside;
        nbnum -= 1;
      } else if (x >= nside) {
        x -= nside;
        nbnum += 1;
      }
      if (y < 0) {
        y += nside;
        nbnum -= 3;
      } else if (y >= nside) {
        y -= nside;
        nbnum += 3;
      }

      final f = _faceArray[nbnum][faceNum];
      if (f < 0) {
        result[i] = -1;
        continue;
      }

      final swap = _swapArray[nbnum][faceNum];
      if ((swap & 1) != 0) x = nside - x - 1;
      if ((swap & 2) != 0) y = nside - y - 1;
      if ((swap & 4) != 0) {
        final t = x;
        x = y;
        y = t;
      }
      result[i] = f * nside * nside + _interleave(x, y);
    }
    return result;
  }

  // Disc query (visible-set enumeration)

  /// Returns the NESTED indices of every pixel whose footprint intersects
  /// (when [inclusive] is true) or whose center lies within (when false) a
  /// spherical cap of angular [radiusDeg] around (RA, Dec) in degrees.
  ///
  /// This is the primary "which tiles are visible" query for the framing
  /// layer: pass the FOV center and a radius covering the diagonal half-FOV
  /// (plus a small margin) to get the candidate tile set at this order.
  ///
  /// Implementation strategy: a robust flood fill from the center pixel over
  /// the [neighboursNest] graph. A pixel is kept when, in inclusive mode,
  /// any of its four corners *or* its center falls within the cap, or the
  /// cap center falls within the pixel — and pruned otherwise. This is exact
  /// for the visible-set use (no false negatives that would drop a visible
  /// tile) and avoids the ring-arithmetic edge cases that make a direct
  /// latitude-band query fragile near the poles and face seams.
  ///
  /// The result is sorted ascending for deterministic output (golden tests).
  List<int> queryDisc(
    double raDeg,
    double decDeg, {
    required double radiusDeg,
    bool inclusive = true,
  }) {
    if (radiusDeg < 0.0) {
      throw HealpixArgumentError('radius must be >= 0, got $radiusDeg');
    }
    if (decDeg < -90.0 || decDeg > 90.0) {
      throw HealpixArgumentError(
        'Declination must be in [-90, 90], got $decDeg',
      );
    }
    final center = _angToVecRaDec(raDeg, decDeg);
    final radiusRad = radiusDeg * math.pi / 180.0;
    final cosRadius = math.cos(radiusRad.clamp(0.0, math.pi));

    // The cap's full angular extent: a pixel can intersect the cap even if
    // its center is up to (radius + pixel-diagonal) away. We grow the
    // acceptance radius by one pixel diagonal for the inclusive test so the
    // flood fill never stops short of a tile that clips the cap edge.
    final pixelDiagRad = inclusive ? _maxPixelDiagRad() : 0.0;
    final cosGrown = math.cos((radiusRad + pixelDiagRad).clamp(0.0, math.pi));

    final start = ang2pixNest(raDeg, decDeg);
    final visited = <int>{};
    final accepted = <int>{};
    final queue = <int>[start];
    visited.add(start);

    while (queue.isNotEmpty) {
      final pix = queue.removeLast();
      // Cheap reject: if the pixel center is well outside the grown cap, it
      // cannot intersect, and neither can it bridge to an accepted pixel
      // through this node — so do not expand it. (Connectivity is preserved
      // because the grown radius covers the worst-case neighbour gap.)
      final ctr = pix2vec(pix);
      final centerInside = ctr.dot(center) >= cosGrown;
      if (!centerInside) {
        continue;
      }

      if (_pixelHitsCap(pix, center, cosRadius, inclusive: inclusive)) {
        accepted.add(pix);
      }

      for (final nb in neighboursNest(pix)) {
        if (nb >= 0 && visited.add(nb)) {
          queue.add(nb);
        }
      }
    }

    final out = accepted.toList()..sort();
    return out;
  }

  // Quadtree (level-of-detail)

  /// Returns the parent pixel index one order coarser (`ipix >> 2`).
  ///
  /// In the NESTED scheme the four children of a tile share its high bits,
  /// so the parent is a pure right shift by two. Throws at [order] 0, which
  /// has no parent.
  int parent(int ipix) {
    _checkPix(ipix);
    if (order == 0) {
      throw HealpixArgumentError('order 0 pixels have no parent');
    }
    return ipix >> 2;
  }

  /// Returns the parent index [levels] orders coarser.
  int ancestorAtOrder(int ipix, int targetOrder) {
    _checkPix(ipix);
    if (targetOrder < 0 || targetOrder > order) {
      throw HealpixArgumentError(
        'targetOrder must be in [0, $order], got $targetOrder',
      );
    }
    return ipix >> (2 * (order - targetOrder));
  }

  /// Returns the four child pixel indices one order finer
  /// (`[ipix*4, ipix*4+1, ipix*4+2, ipix*4+3]`).
  ///
  /// Throws at [maxOrder], which has no finer level.
  List<int> children(int ipix) {
    _checkPix(ipix);
    if (order == maxOrder) {
      throw HealpixArgumentError('order $maxOrder pixels have no children');
    }
    final base = ipix << 2;
    return [base, base + 1, base + 2, base + 3];
  }

  /// Returns the descendant index of [ipix] at the finer [targetOrder] whose
  /// quadtree path is given by the bit-pair sequence implied by mapping the
  /// pixel center down — convenience for "which finer tile contains this
  /// pixel's center". For an explicit child, prefer [children].
  int childAtOrder(int ipix, int targetOrder) {
    _checkPix(ipix);
    if (targetOrder < order || targetOrder > maxOrder) {
      throw HealpixArgumentError(
        'targetOrder must be in [$order, $maxOrder], got $targetOrder',
      );
    }
    final a = pix2ang(ipix);
    return HealpixNested(targetOrder).angToPixNest(a);
  }

  // Internal: (z, phi) <-> nest

  int _zphiToNest(double z, double phi) => xyfToNest(_zphiToXyf(z, phi));

  /// Continuous (z, phi) -> fractional (x, y, face). Górski Eq. (12)-(15)
  /// in continuous form so it serves both pixel addressing (floor the
  /// result) and sub-pixel sampling.
  HealpixXyf _zphiToXyf(double z, double phi) {
    final za = z.abs();
    // tt in [0,4): the longitude scaled to "face columns".
    final tt = _wrapTwoPi(phi) / (math.pi / 2.0); // [0,4)

    final double fx;
    final double fy;
    final int face;

    if (za <= 2.0 / 3.0) {
      // Equatorial belt.
      final temp1 = 0.5 + tt; // [0.5, 4.5)
      final temp2 = z * 0.75; // (-0.5, 0.5)
      final jp = temp1 - temp2; // ascending edge index (float)
      final jm = temp1 + temp2; // descending edge index (float)

      final ifp = jp.floor(); // [0,4]
      final ifm = jm.floor();
      final faceBelt = _equatorFace(ifp, ifm);
      face = faceBelt;
      // Fractional position within the face along the two diagonals.
      fx = (jm - ifm.toDouble());
      fy = 1.0 - (jp - ifp.toDouble());
    } else {
      // Polar cap.
      final ntt = tt.floor().clamp(0, 3); // face column [0,3]
      final tp = tt - ntt; // [0,1)
      final tmp = math.sqrt(3.0 * (1.0 - za)); // (0,1]

      // Distances from the cap corner along the two diagonals.
      final jp = tp * tmp;
      final jm = (1.0 - tp) * tmp;

      if (z > 0.0) {
        face = ntt; // north cap faces 0..3
        fx = 1.0 - jm;
        fy = 1.0 - jp;
      } else {
        face = ntt + 8; // south cap faces 8..11
        fx = jp;
        fy = jm;
      }
    }

    // Scale normalized [0,1] face coords up to [0, Nside].
    var x = fx * nside;
    var y = fy * nside;
    // Guard the inclusive upper edge against tiny FP overshoot so flooring
    // still lands inside [0, Nside) for the integer addressing callers.
    if (x >= nside) x = nside.toDouble() - _edgeEpsilon;
    if (y >= nside) y = nside.toDouble() - _edgeEpsilon;
    if (x < 0.0) x = 0.0;
    if (y < 0.0) y = 0.0;
    return HealpixXyf(x, y, face);
  }

  // Internal helpers

  /// Chooses the equatorial-belt face from the two diagonal edge indices.
  int _equatorFace(int ifp, int ifm) {
    if (ifp == ifm) {
      // Same face column on both diagonals → equatorial face 4..7.
      return (ifp & 3) + 4;
    } else if (ifp < ifm) {
      // North-side face 0..3.
      return ifp & 3;
    } else {
      // South-side face 8..11.
      return (ifm & 3) + 8;
    }
  }

  /// Whether pixel [pix] intersects the cap centered on [center] with the
  /// given cosine threshold. In inclusive mode any corner inside, the
  /// center inside, or the cap-center inside the pixel counts as a hit.
  bool _pixelHitsCap(
    int pix,
    Vector3 center,
    double cosRadius, {
    required bool inclusive,
  }) {
    final ctr = pix2vec(pix);
    if (ctr.dot(center) >= cosRadius) {
      return true; // center inside the cap
    }
    if (!inclusive) {
      return false;
    }
    // Inclusive: any corner inside?
    for (final c in boundaryVectors(pix)) {
      if (c.dot(center) >= cosRadius) {
        return true;
      }
    }
    // Or the cap center inside the pixel footprint (a small cap fully
    // contained in one big tile). Containment test: the cap center maps to
    // this pixel.
    return ang2pixNest(_radFromVec(center).raDeg, _radFromVec(center).decDeg) ==
        pix;
  }

  /// Worst-case half-diagonal of a pixel at this order, in radians.
  ///
  /// Used to grow the flood-fill acceptance radius so no tile clipping the
  /// cap edge is missed. The largest HEALPix pixels are the equatorial ones;
  /// their angular diagonal is bounded by the great-circle distance between
  /// opposite corners of an equatorial pixel. We compute it directly from
  /// pixel 0's geometry scaled to the equator, which is an upper bound for
  /// all pixels (polar pixels are smaller in this metric).
  double _maxPixelDiagRad() {
    // Mean pixel solid angle is 4π/Npix; a generous, always-sufficient
    // bound on the corner-to-corner separation is 2× the radius of an
    // equal-area disc, which is what we use. This never underestimates, so
    // the inclusive flood fill never drops a clipping tile.
    final solidAngle = 4.0 * math.pi / npix;
    final discRadius = math.acos((1.0 - solidAngle / (2.0 * math.pi)));
    return 2.0 * discRadius;
  }

  void _checkPix(int ipix) {
    if (ipix < 0 || ipix >= npix) {
      throw HealpixArgumentError(
        'pixel index must be in [0, $npix) for order $order, got $ipix',
      );
    }
  }

  // Static numeric utilities

  /// Tiny inset used to keep an inclusive upper-edge coordinate inside the
  /// half-open integer range when flooring for pixel addressing.
  static const double _edgeEpsilon = 1e-12;

  static int _log2(int v) {
    var n = 0;
    var x = v;
    while (x > 1) {
      x >>= 1;
      n++;
    }
    return n;
  }

  /// Interleaves the bits of [x] (even positions) and [y] (odd positions)
  /// to form the Morton / Z-order intra-face index used by NESTED numbering.
  static int _interleave(int x, int y) {
    return _spread(x) | (_spread(y) << 1);
  }

  /// Spreads the low 32 bits of [v] so each bit b moves to position 2b.
  static int _spread(int v) {
    var x = v & 0xFFFFFFFF;
    x = (x | (x << 16)) & 0x0000FFFF0000FFFF;
    x = (x | (x << 8)) & 0x00FF00FF00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F0F0F0F0F;
    x = (x | (x << 2)) & 0x3333333333333333;
    x = (x | (x << 1)) & 0x5555555555555555;
    return x;
  }

  /// Inverse of [_spread] reading the even bit positions (the x lattice).
  static int _deinterleaveEven(int v) => _compact(v);

  /// Inverse of [_spread] reading the odd bit positions (the y lattice).
  static int _deinterleaveOdd(int v) => _compact(v >> 1);

  /// Compacts every other bit of [v] (positions 0,2,4,...) back down.
  static int _compact(int v) {
    var x = v & 0x5555555555555555;
    x = (x | (x >> 1)) & 0x3333333333333333;
    x = (x | (x >> 2)) & 0x0F0F0F0F0F0F0F0F;
    x = (x | (x >> 4)) & 0x00FF00FF00FF00FF;
    x = (x | (x >> 8)) & 0x0000FFFF0000FFFF;
    x = (x | (x >> 16)) & 0x00000000FFFFFFFF;
    return x;
  }

  static double _wrapTwoPi(double a) {
    const twoPi = 2.0 * math.pi;
    var r = a % twoPi;
    if (r < 0.0) r += twoPi;
    return r;
  }

  // Static coordinate conversions (no order dependence)

  /// Converts a HEALPix `(theta, phi)` direction to a unit vector.
  static Vector3 angToVec(HealpixAngle a) {
    final st = math.sin(a.theta);
    return Vector3(
      st * math.cos(a.phi),
      st * math.sin(a.phi),
      math.cos(a.theta),
    );
  }

  static Vector3 _angToVecRaDec(double raDeg, double decDeg) {
    final ra = raDeg * math.pi / 180.0;
    final dec = decDeg * math.pi / 180.0;
    final cd = math.cos(dec);
    return Vector3(cd * math.cos(ra), cd * math.sin(ra), math.sin(dec));
  }

  static HealpixAngle _radFromVec(Vector3 v) {
    final len = v.length;
    final theta = math.acos((v.z / len).clamp(-1.0, 1.0));
    final phi = _wrapTwoPi(math.atan2(v.y, v.x));
    return HealpixAngle(theta, phi);
  }
}
