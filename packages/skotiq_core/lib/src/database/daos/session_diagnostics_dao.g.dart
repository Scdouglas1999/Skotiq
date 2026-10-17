// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session_diagnostics_dao.dart';

// ignore_for_file: type=lint
mixin _$SessionDiagnosticsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $SessionDiagnosticsTable get sessionDiagnostics =>
      attachedDatabase.sessionDiagnostics;
  SessionDiagnosticsDaoManager get managers =>
      SessionDiagnosticsDaoManager(this);
}

class SessionDiagnosticsDaoManager {
  final _$SessionDiagnosticsDaoMixin _db;
  SessionDiagnosticsDaoManager(this._db);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$ImagingSessionsTableTableManager get imagingSessions =>
      $$ImagingSessionsTableTableManager(
        _db.attachedDatabase,
        _db.imagingSessions,
      );
  $$SessionDiagnosticsTableTableManager get sessionDiagnostics =>
      $$SessionDiagnosticsTableTableManager(
        _db.attachedDatabase,
        _db.sessionDiagnostics,
      );
}
