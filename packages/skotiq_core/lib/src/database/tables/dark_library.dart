import 'package:drift/drift.dart';

/// Stores dark and bias calibration frames for the dark frame library.
///
/// Each row represents either a single raw dark/bias frame or a master dark
/// (median-stacked from multiple raws). The library supports auto-matching
/// light frames to the best available dark by exposure, temperature, gain,
/// offset, and binning.
@DataClassName('DarkLibraryEntry')
@TableIndex(name: 'idx_dark_library_frame_type', columns: {#frameType})
@TableIndex(name: 'idx_dark_library_exposure', columns: {#exposureTime})
@TableIndex(name: 'idx_dark_library_temperature', columns: {#temperature})
@TableIndex(name: 'idx_dark_library_gain', columns: {#gain})
@TableIndex(
  name: 'idx_dark_library_match',
  columns: {#frameType, #exposureTime, #gain, #binX, #binY},
)
@TableIndex(name: 'idx_dark_library_created', columns: {#createdAt})
class DarkLibrary extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Absolute path to the raw or master dark FITS/XISF file
  TextColumn get filePath => text()();

  /// Exposure duration in seconds
  RealColumn get exposureTime => real()();

  /// Sensor temperature in degrees Celsius at time of capture
  RealColumn get temperature => real().nullable()();

  /// Camera gain setting
  IntColumn get gain => integer().withDefault(const Constant(0))();

  /// Camera offset setting
  IntColumn get offset => integer().withDefault(const Constant(0))();

  /// Horizontal binning
  IntColumn get binX => integer().withDefault(const Constant(1))();

  /// Vertical binning
  IntColumn get binY => integer().withDefault(const Constant(1))();

  /// Frame type: 'dark' or 'bias'
  TextColumn get frameType => text().withDefault(const Constant('dark'))();

  /// Sensor width in pixels
  IntColumn get width => integer().nullable()();

  /// Sensor height in pixels
  IntColumn get height => integer().nullable()();

  /// If this is a master dark, the path to the stacked result.
  /// Null for individual raw frames.
  TextColumn get masterDarkPath => text().nullable()();

  /// Number of raw frames that were median-combined to produce this master.
  /// Null for individual raw frames.
  IntColumn get masterFrameCount => integer().nullable()();

  /// When this frame was captured or the master was created
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
