import 'package:drift/drift.dart';

import 'equipment_profiles.dart';

/// Stores historical polar alignment results for tracking improvement over time
@DataClassName('PolarAlignmentHistoryEntry')
@TableIndex(name: 'idx_polar_history_profile', columns: {#equipmentProfileId})
@TableIndex(name: 'idx_polar_history_started', columns: {#startedAt})
@TableIndex(name: 'idx_polar_history_completed', columns: {#completedAt})
class PolarAlignmentHistory extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Reference to equipment profile used (nullable for unassociated sessions)
  IntColumn get equipmentProfileId => integer().nullable().references(
    EquipmentProfiles,
    #id,
    onDelete: KeyAction.cascade,
  )();

  /// Initial azimuth error in arcseconds
  RealColumn get initialAzimuthError => real()();

  /// Initial altitude error in arcseconds
  RealColumn get initialAltitudeError => real()();

  /// Initial total error in arcseconds
  RealColumn get initialTotalError => real()();

  /// Final azimuth error in arcseconds
  RealColumn get finalAzimuthError => real()();

  /// Final altitude error in arcseconds
  RealColumn get finalAltitudeError => real()();

  /// Final total error in arcseconds
  RealColumn get finalTotalError => real()();

  DateTimeColumn get startedAt => dateTime()();

  DateTimeColumn get completedAt => dateTime()();

  /// Whether alignment was auto-completed (reached threshold)
  BoolColumn get autoCompleted =>
      boolean().withDefault(const Constant(false))();

  /// Whether observing from northern hemisphere
  BoolColumn get isNorth => boolean().withDefault(const Constant(true))();

  /// Full configuration JSON for reference
  TextColumn get configJson => text()();
}
