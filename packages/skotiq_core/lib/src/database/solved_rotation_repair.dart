/// Rewrites `captured_images.solved_rotation` where it disagrees with the
/// row's own stored CD matrix.
///
/// The rotation is derived from the CD matrix with the native `.wcs` parser's
/// convention: `atan2(cd2_1, -cd1_1)` for sky parity and `atan2(cd2_1, cd1_1)`
/// for a mirrored frame (det CD > 0). Rows written before that parser learned
/// the mirrored case carry 180 degrees minus the true angle; any consumer that
/// reads only the scalar rotation is then 137 degrees off on a Newtonian
/// frame. The repair only ever moves the scalar to what the stored matrix
/// already says, so it is idempotent and safe on every open.
library;

import 'dart:math' as math;

import 'package:drift/drift.dart';

/// Rotation in degrees implied by a CD matrix (native parser convention).
double rotationFromStoredCd(
  double cd1_1,
  double cd1_2,
  double cd2_1,
  double cd2_2,
) {
  final mirrored = cd1_1 * cd2_2 - cd1_2 * cd2_1 > 0;
  final rad = mirrored ? math.atan2(cd2_1, cd1_1) : math.atan2(cd2_1, -cd1_1);
  return rad * 180.0 / math.pi;
}

/// Bring every solved row's scalar rotation in line with its stored CD
/// matrix. Returns the number of rows rewritten. Rows within [toleranceDeg]
/// are left alone.
Future<int> repairSolvedRotationFromCd(
  DatabaseConnectionUser db, {
  double toleranceDeg = 0.5,
}) async {
  final rows = await db
      .customSelect(
        'SELECT id, solved_rotation, solved_cd1_1, solved_cd1_2, '
        'solved_cd2_1, solved_cd2_2 FROM captured_images '
        'WHERE solved_cd1_1 IS NOT NULL AND solved_cd1_2 IS NOT NULL '
        'AND solved_cd2_1 IS NOT NULL AND solved_cd2_2 IS NOT NULL',
      )
      .get();
  var repaired = 0;
  for (final row in rows) {
    final cd11 = (row.data['solved_cd1_1'] as num).toDouble();
    final cd12 = (row.data['solved_cd1_2'] as num).toDouble();
    final cd21 = (row.data['solved_cd2_1'] as num).toDouble();
    final cd22 = (row.data['solved_cd2_2'] as num).toDouble();
    if (![cd11, cd12, cd21, cd22].every((v) => v.isFinite)) continue;
    if ((cd11 * cd22 - cd12 * cd21).abs() < 1e-30) continue;
    final want = rotationFromStoredCd(cd11, cd12, cd21, cd22);
    final have = (row.data['solved_rotation'] as num?)?.toDouble();
    if (have != null && have.isFinite) {
      final diff = ((want - have) % 360.0 + 540.0) % 360.0 - 180.0;
      if (diff.abs() <= toleranceDeg) continue;
    }
    await db.customStatement(
      'UPDATE captured_images SET solved_rotation = ? WHERE id = ?',
      [want, row.data['id']],
    );
    repaired++;
  }
  return repaired;
}
