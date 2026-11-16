import 'package:drift/drift.dart';

/// One autofocus result of an equipment profile: the temperature, the best
/// focuser position and its HFR, and the filter it was taken through. The
/// whole-profile temperature line and the per-filter offsets are fitted from
/// these.
@DataClassName('FocusHistoryEntry')
@TableIndex(
  name: 'idx_focus_history_points_profile',
  columns: {#profileId, #recordedAt},
)
class FocusHistoryPoints extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The equipment profile's id as the focus screens and the host API name it.
  TextColumn get profileId => text()();
  DateTimeColumn get recordedAt => dateTime()();
  RealColumn get temperatureCelsius => real()();
  IntColumn get focusPosition => integer()();
  RealColumn get hfr => real()();
  TextColumn get filterName => text().nullable()();
}

/// A profile's focus settings and its fitted temperature line: the filter its
/// offsets are measured from, and the line (null until three temperature
/// bands have been focused).
@DataClassName('FocusProfileModelEntry')
class FocusProfileModels extends Table {
  TextColumn get profileId => text()();
  TextColumn get referenceFilter => text().nullable()();

  /// Steps per degree Celsius.
  RealColumn get slope => real().nullable()();

  /// Position at 0 °C.
  RealColumn get intercept => real().nullable()();
  RealColumn get rSquared => real().nullable()();
  IntColumn get pointCount => integer().nullable()();
  DateTimeColumn get modelUpdatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};
}

/// A filter's focus offset from the profile's reference filter.
@DataClassName('FocusFilterOffsetEntry')
class FocusFilterOffsets extends Table {
  TextColumn get profileId => text()();
  TextColumn get filterName => text()();
  TextColumn get referenceFilter => text()();
  IntColumn get offsetSteps => integer()();
  IntColumn get measurementCount => integer()();

  /// 0..1.
  RealColumn get confidence => real()();

  /// `high`, `medium` or `low` (`FilterOffsetConfidence`).
  TextColumn get confidenceBand => text()();
  TextColumn get confidenceReason => text()();
  BoolColumn get temperatureCorrected => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {profileId, filterName};
}
