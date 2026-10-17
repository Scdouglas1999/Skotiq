// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'observing_lists_dao.dart';

// ignore_for_file: type=lint
mixin _$ObservingListsDaoMixin on DatabaseAccessor<SkotiqDatabase> {
  $ObservingListsTable get observingLists => attachedDatabase.observingLists;
  $ObservingListItemsTable get observingListItems =>
      attachedDatabase.observingListItems;
  ObservingListsDaoManager get managers => ObservingListsDaoManager(this);
}

class ObservingListsDaoManager {
  final _$ObservingListsDaoMixin _db;
  ObservingListsDaoManager(this._db);
  $$ObservingListsTableTableManager get observingLists =>
      $$ObservingListsTableTableManager(
        _db.attachedDatabase,
        _db.observingLists,
      );
  $$ObservingListItemsTableTableManager get observingListItems =>
      $$ObservingListItemsTableTableManager(
        _db.attachedDatabase,
        _db.observingListItems,
      );
}
