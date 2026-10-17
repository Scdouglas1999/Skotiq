import 'package:drift/drift.dart';

import 'equipment_profiles.dart';

/// Stores historical flat frame calibration results for learned exposure suggestions
@DataClassName('FlatHistoryEntry')
@TableIndex(name: 'idx_flat_history_profile', columns: {#equipmentProfileId})
@TableIndex(name: 'idx_flat_history_filter', columns: {#filterName})
@TableIndex(name: 'idx_flat_history_timestamp', columns: {#timestamp})
class FlatHistory extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Reference to equipment profile used
  IntColumn get equipmentProfileId => integer().nullable().references(
    EquipmentProfiles,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// Filter name (e.g., "L", "R", "Ha")
  TextColumn get filterName => text()();

  /// Optimal exposure time found (seconds)
  RealColumn get exposureTime => real()();

  /// Target histogram percentage (0-100)
  RealColumn get histogramTarget => real()();

  /// Actual ADU value achieved
  IntColumn get actualAdu => integer()();

  /// Panel brightness used (0-255, null for sky flats)
  IntColumn get panelBrightness => integer().nullable()();

  /// For sky flats: ADU change rate (ADU/second)
  RealColumn get skyAduRate => real().nullable()();

  /// Twilight phase: 'dawn', 'dusk', or null for panel
  TextColumn get twilightPhase => text().nullable()();

  /// Gain setting used
  IntColumn get gain => integer().withDefault(const Constant(0))();

  /// Binning used
  IntColumn get binning => integer().withDefault(const Constant(1))();

  /// When this calibration was performed
  DateTimeColumn get timestamp => dateTime().withDefault(currentDateAndTime)();
}
