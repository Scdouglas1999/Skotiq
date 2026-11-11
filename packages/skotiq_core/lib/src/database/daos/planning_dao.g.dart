// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'planning_dao.dart';

// ignore_for_file: type=lint
mixin _$PlanningDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  Projects get projects => attachedDatabase.projects;
  $TargetsTable get targets => attachedDatabase.targets;
  ProjectTargets get projectTargets => attachedDatabase.projectTargets;
  IntegrationGoals get integrationGoals => attachedDatabase.integrationGoals;
  TargetConstraints get targetConstraints => attachedDatabase.targetConstraints;
  HorizonProfiles get horizonProfiles => attachedDatabase.horizonProfiles;
  SchedulerRemovedTargets get schedulerRemovedTargets =>
      attachedDatabase.schedulerRemovedTargets;
  Campaigns get campaigns => attachedDatabase.campaigns;
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $CapturedImagesTable get capturedImages => attachedDatabase.capturedImages;
  PlanningDaoManager get managers => PlanningDaoManager(this);
}

class PlanningDaoManager {
  final _$PlanningDaoMixin _db;
  PlanningDaoManager(this._db);
  $ProjectsTableManager get projects =>
      $ProjectsTableManager(_db.attachedDatabase, _db.projects);
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
  $ProjectTargetsTableManager get projectTargets =>
      $ProjectTargetsTableManager(_db.attachedDatabase, _db.projectTargets);
  $IntegrationGoalsTableManager get integrationGoals =>
      $IntegrationGoalsTableManager(_db.attachedDatabase, _db.integrationGoals);
  $TargetConstraintsTableManager get targetConstraints =>
      $TargetConstraintsTableManager(
        _db.attachedDatabase,
        _db.targetConstraints,
      );
  $HorizonProfilesTableManager get horizonProfiles =>
      $HorizonProfilesTableManager(_db.attachedDatabase, _db.horizonProfiles);
  $SchedulerRemovedTargetsTableManager get schedulerRemovedTargets =>
      $SchedulerRemovedTargetsTableManager(
        _db.attachedDatabase,
        _db.schedulerRemovedTargets,
      );
  $CampaignsTableManager get campaigns =>
      $CampaignsTableManager(_db.attachedDatabase, _db.campaigns);
  $$EquipmentProfilesTableTableManager get equipmentProfiles =>
      $$EquipmentProfilesTableTableManager(
        _db.attachedDatabase,
        _db.equipmentProfiles,
      );
  $$SequencesTableTableManager get sequences =>
      $$SequencesTableTableManager(_db.attachedDatabase, _db.sequences);
  $$ImagingSessionsTableTableManager get imagingSessions =>
      $$ImagingSessionsTableTableManager(
        _db.attachedDatabase,
        _db.imagingSessions,
      );
  $$CapturedImagesTableTableManager get capturedImages =>
      $$CapturedImagesTableTableManager(
        _db.attachedDatabase,
        _db.capturedImages,
      );
}
