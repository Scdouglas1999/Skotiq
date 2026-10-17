// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sky_atlas_dao.dart';

// ignore_for_file: type=lint
mixin _$SkyAtlasDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $EquipmentProfilesTable get equipmentProfiles =>
      attachedDatabase.equipmentProfiles;
  $TargetsTable get targets => attachedDatabase.targets;
  $SequencesTable get sequences => attachedDatabase.sequences;
  $ImagingSessionsTable get imagingSessions => attachedDatabase.imagingSessions;
  $SkyAtlasRegionsTable get skyAtlasRegions => attachedDatabase.skyAtlasRegions;
  $SkyTilesTable get skyTiles => attachedDatabase.skyTiles;
  $SkyAtlasFoldsTable get skyAtlasFolds => attachedDatabase.skyAtlasFolds;
  SkyAtlasDaoManager get managers => SkyAtlasDaoManager(this);
}

class SkyAtlasDaoManager {
  final _$SkyAtlasDaoMixin _db;
  SkyAtlasDaoManager(this._db);
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
  $$SkyAtlasRegionsTableTableManager get skyAtlasRegions =>
      $$SkyAtlasRegionsTableTableManager(
        _db.attachedDatabase,
        _db.skyAtlasRegions,
      );
  $$SkyTilesTableTableManager get skyTiles =>
      $$SkyTilesTableTableManager(_db.attachedDatabase, _db.skyTiles);
  $$SkyAtlasFoldsTableTableManager get skyAtlasFolds =>
      $$SkyAtlasFoldsTableTableManager(_db.attachedDatabase, _db.skyAtlasFolds);
}
