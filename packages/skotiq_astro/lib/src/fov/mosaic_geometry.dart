import 'dart:math' as math;

/// The corner of the grid a mosaic starts in, as the grid is drawn: north up
/// and east left at rotation 0, the way the sky looks in the framing view.
enum MosaicStartCorner { topLeft, topRight, bottomLeft, bottomRight }

/// One panel of a mosaic: where it points and its number.
///
/// This is the app's one panel numbering, used by the framing view, the mosaic
/// wizard, the sequencer's panel targets and the FITS mosaic cards:
///
/// * [index] is the panel's place in capture order, from 0; the panel the
///   operator sees numbered "1" is shot first. FITS `PANELIDX` is [number].
/// * [row] counts from the top of the grid as drawn (north at rotation 0) and
///   [col] from the left (east), both from 0, so row/column read the way the
///   grid looks on screen and in FITS `PANELROW`/`PANELCOL`.
///
/// Capture order starts in the chosen [MosaicStartCorner] and, when serpentine,
/// reverses direction on every other row, so a row change is one short slew.
class MosaicPanel {
  /// Right ascension of the panel center, in hours, normalized to [0, 24).
  final double raHours;

  /// Declination of the panel center, in degrees.
  final double decDegrees;

  /// 0-based place in capture order.
  final int index;

  /// 0-based row, from the top of the grid as drawn.
  final int row;

  /// 0-based column, from the left of the grid as drawn.
  final int col;

  const MosaicPanel({
    required this.raHours,
    required this.decDegrees,
    required this.index,
    required this.row,
    required this.col,
  });

  /// The number the operator sees: 1 for the first panel shot.
  int get number => mosaicPanelNumber(index);

  /// "Panel 3".
  String get name => mosaicPanelName(index);
}

/// The number the operator sees for the panel at capture-order [index].
int mosaicPanelNumber(int index) => index + 1;

/// The name of the panel at capture-order [index]: "Panel 3".
String mosaicPanelName(int index) => 'Panel ${mosaicPanelNumber(index)}';

/// The target a panel's frames are filed under: "M31 Mosaic Panel 3".
String mosaicPanelTargetName(String mosaicName, int index) =>
    '$mosaicName ${mosaicPanelName(index)}';

/// Normalize an RA value in hours into the half-open range [0, 24).
///
/// The final `>= 24` fold is not redundant: for a tiny negative input such as
/// `-1e-16`, `raHours % 24.0` is `24.0 - 1e-16`, which rounds to exactly
/// `24.0` in double precision — so the naive version could return 24.0 and
/// break the half-open contract every caller (and every `ra < 24` assertion)
/// relies on.
double normalizeRaHours(double raHours) {
  if (raHours.isNaN || raHours.isInfinite) return raHours;
  var normalized = raHours % 24.0;
  if (normalized < 0) normalized += 24.0;
  if (normalized >= 24.0) normalized = 0.0;
  return normalized;
}

/// The mean of a set of RA values (hours), computed as a **circular** mean so
/// the 0h/24h seam does not corrupt the answer.
///
/// A plain arithmetic mean is wrong for an angle: a mosaic straddling RA 0 has
/// panels at (say) 23.97h and 0.03h, whose arithmetic mean is 12.0h — the
/// opposite side of the sky from the grid it describes. Averaging the unit
/// vectors instead and taking `atan2` gives 0.0h, which is where the mosaic
/// actually is.
///
/// Returns null for an empty input, and for the degenerate case where the
/// vectors cancel to (near) zero — RA values spread symmetrically around the
/// whole circle have no meaningful mean direction, and reporting one would be
/// another confident fiction. Callers should show "unknown" in that case.
double? meanRaHours(Iterable<double> raHours) {
  var sumX = 0.0;
  var sumY = 0.0;
  var count = 0;
  for (final ra in raHours) {
    if (ra.isNaN || ra.isInfinite) continue;
    final angle = ra * math.pi / 12.0; // 24h == 2*pi
    sumX += math.cos(angle);
    sumY += math.sin(angle);
    count++;
  }
  if (count == 0) return null;
  // Resultant length per sample; below this the directions cancel out and the
  // mean angle is numerically meaningless rather than merely imprecise.
  final resultant = math.sqrt(sumX * sumX + sumY * sumY) / count;
  if (resultant < 1e-9) return null;
  return normalizeRaHours(math.atan2(sumY, sumX) * 12.0 / math.pi);
}

/// Convert an east-pointing angular offset (degrees on the sky) into an RA
/// offset in hours at the given declination, applying the cos(dec)
/// compression so a fixed sky-plane step spans more RA near the poles.
///
/// Returns 0 at the singular poles (|cos(dec)| < 1e-6) where RA is undefined.
double raOffsetHoursFromDegrees(double eastOffsetDegrees, double decDegrees) {
  final cosDec = math.cos(decDegrees * math.pi / 180.0);
  if (cosDec.abs() < 1e-6) {
    return 0.0;
  }
  return eastOffsetDegrees / 15.0 / cosDec;
}

/// Lay out a rectangular mosaic: every panel's center and number, in capture
/// order. The single source of truth for panel layout and numbering across
/// the app (see [MosaicPanel]).
///
/// All angular inputs are in **degrees on the sky**:
///
/// * [centerRaHours] / [centerDecDegrees] — the grid center.
/// * [stepRaDegrees] / [stepDecDegrees] — the *effective* center-to-center
///   spacing between adjacent panels (already reduced by overlap).
/// * [columns] / [rows] — grid dimensions.
/// * [rotationDegrees] — camera/grid rotation in the tangent plane.
///
/// Column `c` sits `((columns-1)/2 - c) * stepRaDegrees` east of the center
/// and row `r` `((rows-1)/2 - r) * stepDecDegrees` north of it, rotated, then
/// mapped to RA/Dec with the cos(dec) compression via
/// [raOffsetHoursFromDegrees].
List<MosaicPanel> mosaicPanelCenters({
  required double centerRaHours,
  required double centerDecDegrees,
  required double stepRaDegrees,
  required double stepDecDegrees,
  required int columns,
  required int rows,
  double rotationDegrees = 0.0,
  MosaicStartCorner startCorner = MosaicStartCorner.topLeft,
  bool serpentine = true,
}) {
  final halfHorizontal = (columns - 1) / 2.0;
  final halfVertical = (rows - 1) / 2.0;

  final hasRotation = rotationDegrees != 0.0;
  final rotRad = rotationDegrees * math.pi / 180.0;
  final cosRot = hasRotation ? math.cos(rotRad) : 1.0;
  final sinRot = hasRotation ? math.sin(rotRad) : 0.0;

  final fromBottom = startCorner == MosaicStartCorner.bottomLeft ||
      startCorner == MosaicStartCorner.bottomRight;
  final fromRight = startCorner == MosaicStartCorner.topRight ||
      startCorner == MosaicStartCorner.bottomRight;

  final centers = <MosaicPanel>[];
  for (var pass = 0; pass < rows; pass++) {
    final row = fromBottom ? rows - 1 - pass : pass;
    final rightToLeft = fromRight != (serpentine && pass.isOdd);
    for (var step = 0; step < columns; step++) {
      final col = rightToLeft ? columns - 1 - step : step;
      final eastDeg = (halfHorizontal - col) * stepRaDegrees;
      final northDeg = (halfVertical - row) * stepDecDegrees;

      final double dRaDeg;
      final double dDecDeg;
      if (hasRotation) {
        dRaDeg = eastDeg * cosRot - northDeg * sinRot;
        dDecDeg = eastDeg * sinRot + northDeg * cosRot;
      } else {
        dRaDeg = eastDeg;
        dDecDeg = northDeg;
      }

      centers.add(
        MosaicPanel(
          raHours: normalizeRaHours(
            centerRaHours + raOffsetHoursFromDegrees(dRaDeg, centerDecDegrees),
          ),
          decDegrees: centerDecDegrees + dDecDeg,
          index: centers.length,
          row: row,
          col: col,
        ),
      );
    }
  }
  return centers;
}
