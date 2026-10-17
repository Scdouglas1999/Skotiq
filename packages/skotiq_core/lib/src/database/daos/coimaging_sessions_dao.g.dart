// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'coimaging_sessions_dao.dart';

// ignore_for_file: type=lint
mixin _$CoImagingSessionsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $CoImagingSessionsTable get coImagingSessions =>
      attachedDatabase.coImagingSessions;
  CoImagingSessionsDaoManager get managers => CoImagingSessionsDaoManager(this);
}

class CoImagingSessionsDaoManager {
  final _$CoImagingSessionsDaoMixin _db;
  CoImagingSessionsDaoManager(this._db);
  $$CoImagingSessionsTableTableManager get coImagingSessions =>
      $$CoImagingSessionsTableTableManager(
        _db.attachedDatabase,
        _db.coImagingSessions,
      );
}
