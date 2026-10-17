import 'package:drift/drift.dart';

/// Stores per-camera defect maps (bad-pixel cosmetic correction).
///
/// A defect map is keyed by the combination of camera id, sensor width,
/// sensor height, and temperature bucket (nearest 5 deci-degrees Celsius,
/// stored ×10 so -22.5C is -225). A camera at different sensor cooling
/// setpoints has different hot/cold pixel sets, so each bucket gets its
/// own row. The packed bitmap (1 bit per pixel, row-major) is stored as
/// a blob.
@DataClassName('DefectMapEntry')
@TableIndex(
  name: 'idx_defect_maps_lookup',
  columns: {#cameraId, #width, #height, #temperatureBucketDecicelsius},
  unique: true,
)
class DefectMaps extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Camera identifier (e.g. `native:zwo:ASI2600MC` or `ascom:ZWO.ASICamera2`).
  TextColumn get cameraId => text()();

  /// Sensor width in pixels.
  IntColumn get width => integer()();

  /// Sensor height in pixels.
  IntColumn get height => integer()();

  /// Temperature bucket in deci-degrees Celsius (so -200 means -20.0 C).
  /// Bucketed to the nearest 5 C.
  IntColumn get temperatureBucketDecicelsius => integer()();

  /// Packed bitmap: bit i represents pixel i = y * width + x (row-major,
  /// LSB-first). Length is ceil(width * height / 8) bytes.
  BlobColumn get bitmap => blob()();

  /// Cached count of defective pixels, equal to the popcount of `bitmap`.
  /// Stored so the UI can show a status without scanning the blob.
  IntColumn get defectivePixelCount => integer()();

  /// Path to the `.ndm` file on disk that is the authoritative copy of
  /// this map. The blob in the database mirrors it for offline use.
  TextColumn get filePath => text().nullable()();

  /// When the map was last (re)built from a dark stack.
  DateTimeColumn get lastRebuiltAt =>
      dateTime().withDefault(currentDateAndTime)();
}
