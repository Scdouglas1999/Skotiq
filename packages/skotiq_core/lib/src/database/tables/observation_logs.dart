import 'package:drift/drift.dart';

import 'equipment_profiles.dart';

/// Stores observation log entries with timestamps, notes, and sky conditions.
/// Each entry records an observation of an astronomical object, including
/// coordinates, conditions, and user-supplied notes/rating.
@DataClassName('ObservationLogEntry')
@TableIndex(name: 'idx_obs_logs_timestamp', columns: {#timestamp})
@TableIndex(name: 'idx_obs_logs_object_name', columns: {#objectName})
@TableIndex(name: 'idx_obs_logs_catalog_id', columns: {#catalogId})
@TableIndex(name: 'idx_obs_logs_rating', columns: {#rating})
@TableIndex(name: 'idx_obs_logs_profile', columns: {#equipmentProfileId})
class ObservationLogs extends Table {
  /// Primary key
  IntColumn get id => integer().autoIncrement()();

  /// When the observation was made
  DateTimeColumn get timestamp => dateTime()();

  /// Display name of the observed object (e.g., "Orion Nebula", "M42")
  TextColumn get objectName => text().withLength(min: 1, max: 300)();

  /// Object type (e.g., "galaxy", "nebula", "cluster", "star", "planet")
  TextColumn get objectType => text().nullable()();

  /// Catalog identifier (e.g., "M42", "NGC7000", "IC434")
  TextColumn get catalogId => text().nullable()();

  /// Right ascension in decimal hours (J2000)
  RealColumn get ra => real()();

  /// Declination in decimal degrees (J2000)
  RealColumn get dec => real()();

  /// Altitude above horizon in degrees at time of observation
  RealColumn get altitude => real().nullable()();

  /// Azimuth in degrees at time of observation
  RealColumn get azimuth => real().nullable()();

  /// User-supplied notes about the observation
  TextColumn get notes => text().nullable()();

  /// User rating 1-5 stars
  IntColumn get rating => integer().nullable()();

  /// Equipment profile used during the observation
  IntColumn get equipmentProfileId => integer().nullable().references(
    EquipmentProfiles,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// Seeing conditions description (e.g., "excellent", "good", "fair", "poor")
  TextColumn get seeingConditions => text().nullable()();

  /// Transparency description (e.g., "excellent", "good", "fair", "poor")
  TextColumn get transparency => text().nullable()();

  /// Name of the observing location
  TextColumn get locationName => text().nullable()();

  /// Observer latitude in decimal degrees
  RealColumn get latitude => real().nullable()();

  /// Observer longitude in decimal degrees
  RealColumn get longitude => real().nullable()();
}
