import 'package:drift/drift.dart';

import 'imaging_sessions.dart';
import 'targets.dart';

@DataClassName('CapturedImage')
@TableIndex(name: 'idx_images_session', columns: {#sessionId})
@TableIndex(name: 'idx_images_target', columns: {#targetId})
@TableIndex(name: 'idx_images_frame_type', columns: {#frameType})
@TableIndex(name: 'idx_images_captured_at', columns: {#capturedAt})
@TableIndex(name: 'idx_images_filter', columns: {#filter})
@TableIndex(name: 'idx_images_accepted', columns: {#isAccepted})
@TableIndex(name: 'idx_images_session_frame', columns: {#sessionId, #frameType})
@TableIndex(
  name: 'idx_images_session_captured_at',
  columns: {#sessionId, #capturedAt},
)
@TableIndex(name: 'idx_images_producing_node', columns: {#producingNodeId})
@TableIndex(name: 'idx_images_producing_run', columns: {#producingRunId})
@TableIndex(
  name: 'idx_images_node_captured_at',
  columns: {#producingNodeId, #capturedAt},
)
class CapturedImages extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get filePath => text()();
  TextColumn get fileName => text()();
  TextColumn get fileFormat =>
      text().withDefault(const Constant('fits'))(); // fits, xisf, raw
  IntColumn get fileSize => integer().nullable()();

  IntColumn get sessionId => integer().nullable().references(
    ImagingSessions,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get targetId => integer().nullable().references(
    Targets,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get frameType =>
      text().withDefault(const Constant('light'))(); // light, dark, flat, bias

  RealColumn get exposureDuration => real()();
  IntColumn get gain => integer().nullable()();
  IntColumn get offset => integer().nullable()();
  IntColumn get binX => integer().withDefault(const Constant(1))();
  IntColumn get binY => integer().withDefault(const Constant(1))();
  TextColumn get filter => text().nullable()();

  RealColumn get sensorTemp => real().nullable()();
  RealColumn get coolerPower => real().nullable()();

  RealColumn get hfr => real().nullable()();
  IntColumn get starCount => integer().nullable()();
  RealColumn get background => real().nullable()();
  RealColumn get noise => real().nullable()();
  RealColumn get qualityScore => real()
      .nullable()(); // 0-100 quality score based on HFR, stars, uniformity

  // Guiding data during exposure
  RealColumn get guidingRmsRa => real().nullable()();
  RealColumn get guidingRmsDec => real().nullable()();
  RealColumn get guidingRmsTotal => real().nullable()();

  // Mount position.
  //
  // UNITS: `mountRa` is HOURS (0-24), the ASCOM `RightAscension` convention
  // Skotiq carries internally, while `mountDec`/`mountAltitude`/
  // `mountAzimuth` are DEGREES. The mixed pair is deliberate and validated
  // (see the 0-24 bound in the headless session handler), but it is NOT the
  // FITS convention: the numeric FITS `RA` card is degrees, so the bridge
  // multiplies by 15 when it writes a header. Do not copy this value into a
  // degrees-valued field without converting.
  RealColumn get mountRa => real().nullable()();
  RealColumn get mountDec => real().nullable()();
  RealColumn get mountAltitude => real().nullable()();
  RealColumn get mountAzimuth => real().nullable()();
  TextColumn get pierSide => text().nullable()();

  IntColumn get focuserPosition => integer().nullable()();
  RealColumn get focuserTemp => real().nullable()();

  RealColumn get rotatorAngle => real().nullable()();

  BoolColumn get isPlateSolved =>
      boolean().withDefault(const Constant(false))();
  RealColumn get solvedRa => real().nullable()();
  RealColumn get solvedDec => real().nullable()();
  RealColumn get solvedRotation => real().nullable()();
  RealColumn get solvedPixelScale => real().nullable()();

  DateTimeColumn get capturedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// When this frame was folded into the personal sky atlas (Pillar A), or null
  /// if it has not been folded. The solved-frame fold hook stamps this after a
  /// successful fold and skips re-folding when it is already set, so a duplicate
  /// inbound `updateCapturedImage{isPlateSolved:true}` (plausible in the
  /// master/slave sync architecture) cannot double-count photons.
  DateTimeColumn get atlasFoldedAt => dateTime().nullable()();

  BoolColumn get isAccepted =>
      boolean().withDefault(const Constant(true))(); // For rejection marking
  TextColumn get rejectionReason => text().nullable()();

  // Which instruction of which run produced the frame, and the grade the
  // run gave it while it was still executing.
  TextColumn get producingNodeId => text().nullable()();
  TextColumn get producingRunId => text().nullable()();
  TextColumn get runtimeGrade => text().nullable()();

  RealColumn get eccentricity => real().nullable()();
  RealColumn get fwhm => real().nullable()();

  // Anisotropic WCS of the solve: the CD matrix (degrees per pixel) and the
  // SIP distortion terms as JSON.
  RealColumn get solvedCd1_1 => real().named('solved_cd1_1').nullable()();
  RealColumn get solvedCd1_2 => real().named('solved_cd1_2').nullable()();
  RealColumn get solvedCd2_1 => real().named('solved_cd2_1').nullable()();
  RealColumn get solvedCd2_2 => real().named('solved_cd2_2').nullable()();
  TextColumn get solvedSip => text().nullable()();

  TextColumn get thumbnailPath => text().nullable()();

  /// When a plate solver ran on the frame and found no solution, as unix
  /// MILLISECONDS. A frame with neither this nor `isPlateSolved` was never
  /// sent to a solver, so solve-rate statistics leave it out.
  IntColumn get plateSolveFailedAt => integer().nullable()();
}

/// Extended image metadata table
/// For storing FITS header keywords and other extended metadata
@DataClassName('ImageMetadatum')
@TableIndex(name: 'idx_metadata_image', columns: {#imageId})
@TableIndex(name: 'idx_metadata_key', columns: {#key})
class ImageMetadata extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get imageId =>
      integer().references(CapturedImages, #id, onDelete: KeyAction.cascade)();
  TextColumn get key => text()();
  TextColumn get value => text()();
  TextColumn get comment => text().nullable()();
}
