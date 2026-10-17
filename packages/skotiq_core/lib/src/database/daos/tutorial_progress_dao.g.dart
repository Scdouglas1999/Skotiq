// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tutorial_progress_dao.dart';

// ignore_for_file: type=lint
mixin _$TutorialProgressDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $TutorialProgressTable get tutorialProgress =>
      attachedDatabase.tutorialProgress;
  TutorialProgressDaoManager get managers => TutorialProgressDaoManager(this);
}

class TutorialProgressDaoManager {
  final _$TutorialProgressDaoMixin _db;
  TutorialProgressDaoManager(this._db);
  $$TutorialProgressTableTableManager get tutorialProgress =>
      $$TutorialProgressTableTableManager(
        _db.attachedDatabase,
        _db.tutorialProgress,
      );
}
