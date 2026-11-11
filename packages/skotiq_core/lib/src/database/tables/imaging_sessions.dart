import 'package:drift/drift.dart';

import 'equipment_profiles.dart';
import 'sequences.dart';
import 'targets.dart';

@DataClassName('ImagingSession')
@TableIndex(name: 'idx_sessions_target', columns: {#targetId})
@TableIndex(name: 'idx_sessions_profile', columns: {#profileId})
@TableIndex(name: 'idx_sessions_start', columns: {#startTime})
@TableIndex(name: 'idx_sessions_status', columns: {#status})
@TableIndex(name: 'idx_sessions_sequence', columns: {#sequenceId})
class ImagingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().nullable()();

  IntColumn get profileId => integer().nullable().references(
    EquipmentProfiles,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get targetId => integer().nullable().references(
    Targets,
    #id,
    onDelete: KeyAction.setNull,
  )();

  DateTimeColumn get startTime => dateTime()();
  DateTimeColumn get endTime => dateTime().nullable()();

  IntColumn get totalExposures => integer().withDefault(const Constant(0))();
  IntColumn get successfulExposures =>
      integer().withDefault(const Constant(0))();
  IntColumn get failedExposures => integer().withDefault(const Constant(0))();
  RealColumn get totalIntegrationSecs =>
      real().withDefault(const Constant(0.0))();

  // Weather/conditions at session time
  RealColumn get avgTemperature => real().nullable()();
  RealColumn get avgHumidity => real().nullable()();
  RealColumn get avgSeeing => real().nullable()();

  RealColumn get avgHfr => real().nullable()();
  RealColumn get avgGuidingRms => real().nullable()();
  IntColumn get autofocusCount => integer().withDefault(const Constant(0))();

  TextColumn get notes => text().nullable()();

  TextColumn get status => text().withDefault(const Constant('completed'))();
  // completed, aborted, error

  // Quick Start support: track which sequence was used
  IntColumn get sequenceId => integer().nullable().references(
    Sequences,
    #id,
    onDelete: KeyAction.setNull,
  )();

  // Quick Start support: JSON blob storing equipment state at session start
  TextColumn get equipmentSnapshot => text().nullable()();
}
