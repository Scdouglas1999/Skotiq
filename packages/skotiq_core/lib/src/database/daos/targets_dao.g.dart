// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'targets_dao.dart';

// ignore_for_file: type=lint
mixin _$TargetsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $TargetsTable get targets => attachedDatabase.targets;
  TargetsDaoManager get managers => TargetsDaoManager(this);
}

class TargetsDaoManager {
  final _$TargetsDaoMixin _db;
  TargetsDaoManager(this._db);
  $$TargetsTableTableManager get targets =>
      $$TargetsTableTableManager(_db.attachedDatabase, _db.targets);
}
