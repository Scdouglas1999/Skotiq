import 'package:drift/drift.dart';

import 'captured_images.dart';
import 'imaging_sessions.dart';

/// Pillar B ("First Light") persistence — the difference-imaging transient log.
///
/// Every fresh, plate-solved light frame is differenced against the deep atlas
/// template for the tiles it covers (`api_difference_image`). Each residual
/// source that survives the photometric subtraction is one row here: where it
/// is on the sky, how bright the change was, its shape, and — the headline —
/// whether the Dart cross-match could put a name to it. A null [catalogMatch]
/// on a clean point source is the genuinely exciting case: a possible new
/// transient.
///
/// Nullable-reference convention matches the science tables
/// (`tables/science.dart`): both [sessionId] and [capturedImageId] are nullable
/// so a sessionless or already-deleted-frame detection survives as history. The
/// shape-class [kind] is stored as its stable wire string
/// (`pointBrightening` | `movingStreak` | `dipole` | `newSource`) so a
/// forward-compatible reader degrades gracefully, matching the constants table
/// in `docs/skotiq_5_0_contracts.md`.
@DataClassName('TransientDetectionRow')
@TableIndex(name: 'idx_transient_detections_session', columns: {#sessionId})
@TableIndex(name: 'idx_transient_detections_tile', columns: {#tileId})
@TableIndex(name: 'idx_transient_detections_detected', columns: {#detectedAt})
class TransientDetections extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get sessionId => integer().nullable().references(
    ImagingSessions,
    #id,
    onDelete: KeyAction.cascade,
  )();

  IntColumn get capturedImageId => integer().nullable().references(
    CapturedImages,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// HEALPix NESTED tile id the residual fell on.
  IntColumn get tileId => integer()();

  DateTimeColumn get detectedAt => dateTime().withDefault(currentDateAndTime)();

  /// Sky position resolved through the tile WCS, degrees, J2000.
  RealColumn get raDeg => real()();
  RealColumn get decDeg => real()();

  /// Template-subtracted flux (signed; positive = brighter than the template).
  RealColumn get residualFlux => real()();

  /// Estimated brightness change in magnitudes (negative = brighter). Null for
  /// a true new source with no template flux to compare against.
  RealColumn get deltaMag => real().nullable()();

  RealColumn get snr => real()();
  RealColumn get fwhm => real()();
  RealColumn get eccentricity => real()();

  /// Major-axis position angle (degrees, `[0, 180)`) from the residual's
  /// second-moment covariance — the real measured orientation of an elongated
  /// source (a streak's trail direction). Defaults to 0 for pre-existing rows
  /// written before the native fit reported it.
  RealColumn get positionAngleDeg => real().withDefault(const Constant(0.0))();

  /// Shape/sign class: `pointBrightening` | `movingStreak` | `dipole` |
  /// `newSource`.
  TextColumn get kind => text()();

  /// Resolved object name from the Dart-side cross-match, or null when no
  /// catalog / photometric / moving-object match was found — the headline case
  /// of a possible unknown transient.
  TextColumn get catalogMatch => text().nullable()();

  /// Cross-match confidence in [0, 1]: how strongly the residual is believed to
  /// be a real astrophysical change versus a subtraction artefact.
  RealColumn get confidence => real()();

  /// Whether a human has triaged this detection.
  BoolColumn get reviewed => boolean().withDefault(const Constant(false))();

  /// Whether a human dismissed it as an artefact (kept, not deleted, so the
  /// difference pipeline does not re-surface the same residual every night).
  BoolColumn get dismissed => boolean().withDefault(const Constant(false))();
}
