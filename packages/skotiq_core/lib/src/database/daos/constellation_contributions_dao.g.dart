// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'constellation_contributions_dao.dart';

// ignore_for_file: type=lint
mixin _$ConstellationContributionsDaoMixin
    on DatabaseAccessor<SkotiqDatabase> {
  $ConstellationContributionsTable get constellationContributions =>
      attachedDatabase.constellationContributions;
  ConstellationContributionsDaoManager get managers =>
      ConstellationContributionsDaoManager(this);
}

class ConstellationContributionsDaoManager {
  final _$ConstellationContributionsDaoMixin _db;
  ConstellationContributionsDaoManager(this._db);
  $$ConstellationContributionsTableTableManager
  get constellationContributions =>
      $$ConstellationContributionsTableTableManager(
        _db.attachedDatabase,
        _db.constellationContributions,
      );
}
