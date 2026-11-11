import 'package:drift/drift.dart';

/// User-curated collections of astronomical targets for observing sessions.
@DataClassName('ObservingList')
@TableIndex(name: 'idx_observing_lists_name', columns: {#name})
@TableIndex(name: 'idx_observing_lists_sort_order', columns: {#sortOrder})
class ObservingLists extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// User-chosen name for this list (e.g., "Winter Galaxies", "Messier Marathon")
  TextColumn get name => text().withLength(min: 1, max: 300)();

  TextColumn get description => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Items within an observing list. Each entry stores the catalog info
/// needed to identify the object on the sky, independent of the targets table.
@DataClassName('ObservingListItem')
@TableIndex(name: 'idx_observing_list_items_list', columns: {#listId})
@TableIndex(name: 'idx_observing_list_items_catalog', columns: {#catalogId})
@TableIndex(
  name: 'idx_observing_list_items_sort',
  columns: {#listId, #sortOrder},
)
class ObservingListItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get listId =>
      integer().references(ObservingLists, #id, onDelete: KeyAction.cascade)();

  /// Display name of the object (e.g., "Orion Nebula")
  TextColumn get objectName => text().withLength(min: 1, max: 300)();

  /// Catalog identifier (e.g., "M42", "NGC7000", "IC434")
  TextColumn get catalogId => text().nullable()();

  /// Object type (e.g., "galaxy", "nebula", "cluster")
  TextColumn get objectType => text().nullable()();

  /// Right ascension in decimal hours (J2000)
  RealColumn get ra => real()();

  /// Declination in decimal degrees (J2000)
  RealColumn get dec => real()();

  /// Visual magnitude
  RealColumn get magnitude => real().nullable()();

  /// Angular size in arcminutes
  RealColumn get sizeArcmin => real().nullable()();

  TextColumn get notes => text().nullable()();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {listId, catalogId},
  ];
}
