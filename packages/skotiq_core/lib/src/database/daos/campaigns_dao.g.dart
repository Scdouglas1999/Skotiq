// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'campaigns_dao.dart';

// ignore_for_file: type=lint
mixin _$CampaignsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  Projects get projects => attachedDatabase.projects;
  $TargetsTable get targets => attachedDatabase.targets;
  ProjectTargets get projectTargets => attachedDatabase.projectTargets;
  IntegrationGoals get integrationGoals => attachedDatabase.integrationGoals;
  TargetConstraints get targetConstraints => attachedDatabase.targetConstraints;
  HorizonProfiles get horizonProfiles => attachedDatabase.horizonProfiles;
  SchedulerRemovedTargets get schedulerRemovedTargets =>
      attachedDatabase.schedulerRemovedTargets;
  Campaigns get campaigns => attachedDatabase.campaigns;
  CampaignsDaoManager get managers => CampaignsDaoManager(this);
}

class CampaignsDaoManager {
  final _$CampaignsDaoMixin _db;
  CampaignsDaoManager(this._db);
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
}
