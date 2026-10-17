import 'package:drift/drift.dart';

import 'imaging_sessions.dart';
import 'targets.dart';

/// Captured images table
/// Records metadata for every captured image
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
class CapturedImages extends Table {
  IntColumn get id => integer().autoIncrement()();

  // File information
  TextColumn get filePath => text()();
  TextColumn get fileName => text()();
  TextColumn get fileFormat =>
      text().withDefault(const Constant('fits'))(); // fits, xisf, raw
  IntColumn get fileSize => integer().nullable()();

  // Foreign keys
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

  // Frame type
  TextColumn get frameType =>
      text().withDefault(const Constant('light'))(); // light, dark, flat, bias

  // Exposure settings
  RealColumn get exposureDuration => real()();
  IntColumn get gain => integer().nullable()();
  IntColumn get offset => integer().nullable()();
  IntColumn get binX => integer().withDefault(const Constant(1))();
  IntColumn get binY => integer().withDefault(const Constant(1))();
  TextColumn get filter => text().nullable()();

  // Camera state
  RealColumn get sensorTemp => real().nullable()();
  RealColumn get coolerPower => real().nullable()();

  // Quality metrics
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

  // Focuser position
  IntColumn get focuserPosition => integer().nullable()();
  RealColumn get focuserTemp => real().nullable()();

  // Rotator position
  RealColumn get rotatorAngle => real().nullable()();

  // Plate solve result
  BoolColumn get isPlateSolved =>
      boolean().withDefault(const Constant(false))();
  RealColumn get solvedRa => real().nullable()();
  RealColumn get solvedDec => real().nullable()();
  RealColumn get solvedRotation => real().nullable()();
  RealColumn get solvedPixelScale => real().nullable()();

  // Timestamps
  DateTimeColumn get capturedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// When this frame was folded into the personal sky atlas (Pillar A), or null
  /// if it has not been folded. The solved-frame fold hook stamps this after a
  /// successful fold and skips re-folding when it is already set, so a duplicate
  /// inbound `updateCapturedImage{isPlateSolved:true}` (plausible in the
  /// master/slave sync architecture) cannot double-count photons.
  DateTimeColumn get atlasFoldedAt => dateTime().nullable()();

  // Flags
  BoolColumn get isAccepted =>
      boolean().withDefault(const Constant(true))(); // For rejection marking
  TextColumn get rejectionReason => text().nullable()();

  // Thumbnail: producing-instruction provenance lives in raw-DDL
  // columns (`producing_node_id`, `producing_run_id`, `runtime_grade`,
  // `eccentricity`) added by the v30 migration but NOT declared on the
  // Drift Table here. Same convention as (notes_journal)
  // and the v27/v28 raw-DDL tables — the migration lands without
  // forcing a drift codegen pass, and the new
  // `ImagesDao.watchImagesByProducingNode` reads the columns via
  // `customSelect`.
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
