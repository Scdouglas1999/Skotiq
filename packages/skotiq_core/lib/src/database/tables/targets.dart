import 'package:drift/drift.dart';

/// Astronomical targets table
/// Stores target information for imaging planning
@DataClassName('Target')
@TableIndex(name: 'idx_targets_name', columns: {#name})
@TableIndex(name: 'idx_targets_catalog', columns: {#catalogId})
@TableIndex(name: 'idx_targets_priority', columns: {#priority})
@TableIndex(name: 'idx_targets_favorite', columns: {#isFavorite})
@TableIndex(name: 'idx_targets_object_type', columns: {#objectType})
class Targets extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get catalogId => text().nullable()(); // e.g., "M42", "NGC7000"
  TextColumn get objectType =>
      text().nullable()(); // galaxy, nebula, cluster, etc.

  // Coordinates (J2000)
  RealColumn get ra => real()(); // Right ascension in decimal hours
  RealColumn get dec => real()(); // Declination in decimal degrees

  // Optional position angle for framing
  RealColumn get positionAngle => real().nullable()();

  // Object metadata
  RealColumn get magnitude => real().nullable()(); // Visual magnitude
  TextColumn get constellation => text().nullable()(); // Constellation name
  RealColumn get sizeArcmin =>
      real().nullable()(); // Angular size in arcminutes

  // Planning data
  RealColumn get minAltitude => real().withDefault(const Constant(30.0))();
  IntColumn get priority => integer().withDefault(const Constant(5))();

  // Imaging progress
  IntColumn get totalPlannedSubs => integer().withDefault(const Constant(0))();
  IntColumn get capturedSubs => integer().withDefault(const Constant(0))();
  RealColumn get totalIntegrationSecs =>
      real().withDefault(const Constant(0.0))();
  RealColumn get goalIntegrationSecs =>
      real().withDefault(const Constant(0.0))();

  // Per-filter progress (JSON object)
  TextColumn get filterProgress => text().nullable()();

  // Notes
  TextColumn get notes => text().nullable()();

  // Timestamps
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  // Flag for favorites
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
}
