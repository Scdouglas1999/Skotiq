import 'package:drift/drift.dart';

/// Equipment profiles table
/// Stores different equipment configurations that can be selected
@DataClassName('EquipmentProfile')
@TableIndex(name: 'idx_profiles_name', columns: {#name})
@TableIndex(name: 'idx_profiles_active', columns: {#isActive})
class EquipmentProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 100)();
  TextColumn get description => text().nullable()();

  // Device identifiers (driver-specific IDs)
  TextColumn get cameraId => text().nullable()();
  TextColumn get mountId => text().nullable()();
  TextColumn get focuserId => text().nullable()();
  TextColumn get filterWheelId => text().nullable()();
  TextColumn get guiderId => text().nullable()();
  TextColumn get rotatorId => text().nullable()();
  TextColumn get domeId => text().nullable()();
  TextColumn get weatherId => text().nullable()();
  TextColumn get safetyMonitorId => text().nullable()();
  TextColumn get switchId => text().nullable()();
  TextColumn get coverCalibratorId => text().nullable()();

  // Optical setup
  RealColumn get focalLength => real().withDefault(const Constant(0.0))();
  RealColumn get aperture => real().withDefault(const Constant(0.0))();
  RealColumn get focalRatio => real().nullable()();

  // Camera settings defaults
  IntColumn get defaultGain => integer().nullable()();
  IntColumn get defaultOffset => integer().nullable()();
  IntColumn get defaultBinX => integer().withDefault(const Constant(1))();
  IntColumn get defaultBinY => integer().withDefault(const Constant(1))();
  RealColumn get defaultCoolingTemp => real().nullable()();
  BoolColumn get coolOnConnect =>
      boolean().withDefault(const Constant(false))();

  // Centering/plate-solve exposure default (seconds)
  RealColumn get defaultCenteringExposure => real().nullable()();

  // Filter configuration (JSON array of filter names)
  TextColumn get filterNames => text().nullable()();
  // Filter focus offsets (JSON object mapping filter name to offset)
  TextColumn get filterFocusOffsets => text().nullable()();

  // Meridian flip settings overrides (JSON, nullable - uses global defaults if null)
  TextColumn get meridianFlipOverrides => text().nullable()();

  // User-friendly device names (can be auto-generated or custom)
  TextColumn get cameraName => text().nullable()();
  TextColumn get mountName => text().nullable()();
  TextColumn get focuserName => text().nullable()();
  TextColumn get filterWheelName => text().nullable()();
  TextColumn get guiderName => text().nullable()();
  TextColumn get rotatorName => text().nullable()();
  TextColumn get safetyMonitorName => text().nullable()();
  TextColumn get switchName => text().nullable()();

  // Telescope/OTA information (separate from profile-level optical settings)
  TextColumn get telescopeName => text().nullable()();
  RealColumn get telescopeFocalLength => real().nullable()();
  RealColumn get telescopeAperture => real().nullable()();

  // Profile customization
  TextColumn get profileIcon => text().nullable()();
  IntColumn get profileColor => integer().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  // Timestamps
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // Flag for the currently active profile
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
}
