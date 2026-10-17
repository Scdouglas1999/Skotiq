// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'guide_rms_history_dao.dart';

// ignore_for_file: type=lint
mixin _$GuideRmsHistoryDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $GuideRmsHistoryTable get guideRmsHistory => attachedDatabase.guideRmsHistory;
  GuideRmsHistoryDaoManager get managers => GuideRmsHistoryDaoManager(this);
}

class GuideRmsHistoryDaoManager {
  final _$GuideRmsHistoryDaoMixin _db;
  GuideRmsHistoryDaoManager(this._db);
  $$GuideRmsHistoryTableTableManager get guideRmsHistory =>
      $$GuideRmsHistoryTableTableManager(
        _db.attachedDatabase,
        _db.guideRmsHistory,
      );
}
