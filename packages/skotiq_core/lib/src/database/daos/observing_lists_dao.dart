import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/observing_lists.dart';

part 'observing_lists_dao.g.dart';

/// Thrown by [ObservingListsDao.addItem] when the catalog object is already in
/// the target list.
///
/// Why a type instead of a bare `StateError`: adding something twice is an
/// ordinary thing for a user to do, not a fault, and callers need to tell it
/// apart from a real write failure so they can say "already there" instead of
/// "failed". It still extends [StateError] so the headless API's existing
/// `on StateError` → HTTP 409 mapping keeps working unchanged.
///
/// [toString] drops Dart's `Bad state: ` prefix because callers — the
/// planner's add-to-list dialog among them — render the message verbatim.
class ObservingListDuplicateItemException extends StateError {
  ObservingListDuplicateItemException({
    required this.listId,
    required this.catalogId,
    required this.existingItemId,
    required this.existingObjectName,
  }) : super(
         catalogId == existingObjectName
             ? '$catalogId is already in this list'
             : '$catalogId is already in this list as "$existingObjectName"',
       );

  final int listId;
  final String catalogId;
  final int existingItemId;
  final String existingObjectName;

  @override
  String toString() => message;
}

@DriftAccessor(tables: [ObservingLists, ObservingListItems])
class ObservingListsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$ObservingListsDaoMixin {
  ObservingListsDao(super.db);

  // ─── List CRUD ──────────────────────────────────────────────────────────────

  /// Create a new observing list. Returns the generated row ID.
  Future<int> createList({required String name, String? description}) async {
    final maxOrder = await _maxListSortOrder();
    return into(observingLists).insert(
      ObservingListsCompanion.insert(
        name: name,
        description: Value(description),
        sortOrder: Value(maxOrder + 1),
      ),
    );
  }

  /// Update an existing observing list's name/description.
  Future<void> updateList({
    required int id,
    String? name,
    String? description,
    bool clearDescription = false,
  }) async {
    final companion = ObservingListsCompanion(
      name: name != null ? Value(name) : const Value.absent(),
      description: clearDescription
          ? const Value(null)
          : description != null
          ? Value(description)
          : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    );
    await (update(
      observingLists,
    )..where((t) => t.id.equals(id))).write(companion);
  }

  /// Delete an observing list and all its items (cascade).
  Future<int> deleteList(int id) {
    return (delete(observingLists)..where((t) => t.id.equals(id))).go();
  }

  /// Get all observing lists ordered by sortOrder.
  Future<List<ObservingList>> getAllLists() {
    return (select(
      observingLists,
    )..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
  }

  /// Watch all observing lists as a reactive stream.
  Stream<List<ObservingList>> watchAllLists() {
    return (select(
      observingLists,
    )..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).watch();
  }

  /// Get a single observing list by ID.
  Future<ObservingList?> getListById(int id) {
    return (select(
      observingLists,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Duplicate a list and all its items. Returns the new list's ID.
  Future<int> duplicateList(int sourceListId) async {
    final source = await getListById(sourceListId);
    if (source == null) {
      throw StateError('Observing list $sourceListId not found');
    }

    final newId = await createList(
      name: '${source.name} (copy)',
      description: source.description,
    );

    final items = await getItemsForList(sourceListId);
    for (final item in items) {
      await addItem(
        listId: newId,
        objectName: item.objectName,
        catalogId: item.catalogId,
        objectType: item.objectType,
        ra: item.ra,
        dec: item.dec,
        magnitude: item.magnitude,
        sizeArcmin: item.sizeArcmin,
        notes: item.notes,
      );
    }

    return newId;
  }

  /// Reorder lists by writing new sortOrder values.
  Future<void> reorderLists(List<int> orderedIds) async {
    await transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (update(observingLists)..where((t) => t.id.equals(orderedIds[i])))
            .write(ObservingListsCompanion(sortOrder: Value(i)));
      }
    });
  }

  // ─── Item CRUD ──────────────────────────────────────────────────────────────

  /// Add an item to an observing list. Returns the generated row ID.
  /// If the catalogId already exists in the list, throws an
  /// [ObservingListDuplicateItemException].
  Future<int> addItem({
    required int listId,
    required String objectName,
    String? catalogId,
    String? objectType,
    required double ra,
    required double dec,
    double? magnitude,
    double? sizeArcmin,
    String? notes,
  }) async {
    // Check for duplicate catalog IDs within the same list
    if (catalogId != null) {
      final existing =
          await (select(observingListItems)..where(
                (t) => t.listId.equals(listId) & t.catalogId.equals(catalogId),
              ))
              .getSingleOrNull();
      if (existing != null) {
        throw ObservingListDuplicateItemException(
          listId: listId,
          catalogId: catalogId,
          existingItemId: existing.id,
          existingObjectName: existing.objectName,
        );
      }
    }

    final maxOrder = await _maxItemSortOrder(listId);
    final id = await into(observingListItems).insert(
      ObservingListItemsCompanion.insert(
        listId: listId,
        objectName: objectName,
        catalogId: Value(catalogId),
        objectType: Value(objectType),
        ra: ra,
        dec: dec,
        magnitude: Value(magnitude),
        sizeArcmin: Value(sizeArcmin),
        notes: Value(notes),
        sortOrder: Value(maxOrder + 1),
      ),
    );

    // Touch the parent list's updatedAt
    await (update(observingLists)..where((t) => t.id.equals(listId))).write(
      ObservingListsCompanion(updatedAt: Value(DateTime.now())),
    );

    return id;
  }

  /// Remove an item from an observing list.
  Future<int> removeItem(int itemId) async {
    // Get listId before deleting to update parent timestamp
    final item = await (select(
      observingListItems,
    )..where((t) => t.id.equals(itemId))).getSingleOrNull();

    final result = (delete(
      observingListItems,
    )..where((t) => t.id.equals(itemId))).go();

    if (item != null) {
      await (update(observingLists)..where((t) => t.id.equals(item.listId)))
          .write(ObservingListsCompanion(updatedAt: Value(DateTime.now())));
    }

    return result;
  }

  /// Update notes on a list item. Returns the number of rows written, so a
  /// caller can tell "saved" from "there was no such item" — discarding the
  /// count let the headless API answer `200 {"status":"updated"}` for an id
  /// that does not exist, leaving a client believing an edit had persisted.
  Future<int> updateItemNotes(int itemId, String? notes) {
    return (update(observingListItems)..where((t) => t.id.equals(itemId)))
        .write(ObservingListItemsCompanion(notes: Value(notes)));
  }

  /// Get all items for a given list, ordered by sortOrder.
  Future<List<ObservingListItem>> getItemsForList(int listId) {
    return (select(observingListItems)
          ..where((t) => t.listId.equals(listId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  /// Watch all items for a given list as a reactive stream.
  Stream<List<ObservingListItem>> watchItemsForList(int listId) {
    return (select(observingListItems)
          ..where((t) => t.listId.equals(listId))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .watch();
  }

  /// Reorder items within a list.
  Future<void> reorderItems(int listId, List<int> orderedItemIds) async {
    await transaction(() async {
      for (var i = 0; i < orderedItemIds.length; i++) {
        await (update(observingListItems)
              ..where((t) => t.id.equals(orderedItemIds[i])))
            .write(ObservingListItemsCompanion(sortOrder: Value(i)));
      }
    });
    await (update(observingLists)..where((t) => t.id.equals(listId))).write(
      ObservingListsCompanion(updatedAt: Value(DateTime.now())),
    );
  }

  /// Get the number of items in a list.
  Future<int> getItemCount(int listId) async {
    final countExpr = observingListItems.id.count();
    final query = selectOnly(observingListItems)
      ..addColumns([countExpr])
      ..where(observingListItems.listId.equals(listId));
    final result = await query.map((row) => row.read(countExpr)).getSingle();
    return result ?? 0;
  }

  /// Get all catalog IDs across all lists (for planetarium markers).
  Future<Set<String>> getAllListedCatalogIds() async {
    final query = selectOnly(observingListItems, distinct: true)
      ..addColumns([observingListItems.catalogId])
      ..where(observingListItems.catalogId.isNotNull());
    final results = await query
        .map((row) => row.read(observingListItems.catalogId))
        .get();
    return results.whereType<String>().toSet();
  }

  /// Watch all catalog IDs across all lists as a reactive stream.
  Stream<Set<String>> watchAllListedCatalogIds() {
    final query = selectOnly(observingListItems, distinct: true)
      ..addColumns([observingListItems.catalogId])
      ..where(observingListItems.catalogId.isNotNull());
    return query
        .map((row) => row.read(observingListItems.catalogId))
        .watch()
        .map((list) => list.whereType<String>().toSet());
  }

  /// Get catalog IDs for a specific list (for per-list planetarium markers).
  Future<Set<String>> getCatalogIdsForList(int listId) async {
    final query = selectOnly(observingListItems, distinct: true)
      ..addColumns([observingListItems.catalogId])
      ..where(
        observingListItems.listId.equals(listId) &
            observingListItems.catalogId.isNotNull(),
      );
    final results = await query
        .map((row) => row.read(observingListItems.catalogId))
        .get();
    return results.whereType<String>().toSet();
  }

  /// Watch catalog IDs for a specific list.
  Stream<Set<String>> watchCatalogIdsForList(int listId) {
    final query = selectOnly(observingListItems, distinct: true)
      ..addColumns([observingListItems.catalogId])
      ..where(
        observingListItems.listId.equals(listId) &
            observingListItems.catalogId.isNotNull(),
      );
    return query
        .map((row) => row.read(observingListItems.catalogId))
        .watch()
        .map((list) => list.whereType<String>().toSet());
  }

  /// Check if a catalog ID exists in any list.
  Future<bool> isInAnyList(String catalogId) async {
    final query = select(observingListItems)
      ..where((t) => t.catalogId.equals(catalogId))
      ..limit(1);
    final results = await query.get();
    return results.isNotEmpty;
  }

  /// Get which lists contain a given catalog ID.
  Future<List<ObservingList>> getListsContaining(String catalogId) async {
    final itemQuery = selectOnly(observingListItems, distinct: true)
      ..addColumns([observingListItems.listId])
      ..where(observingListItems.catalogId.equals(catalogId));
    final listIds = await itemQuery
        .map((row) => row.read(observingListItems.listId))
        .get();
    final nonNullIds = listIds.whereType<int>().toList();
    if (nonNullIds.isEmpty) return [];

    return (select(observingLists)
          ..where((t) => t.id.isIn(nonNullIds))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  Future<int> _maxListSortOrder() async {
    final query = selectOnly(observingLists)
      ..addColumns([observingLists.sortOrder.max()]);
    final result = await query
        .map((row) => row.read(observingLists.sortOrder.max()))
        .getSingle();
    return result ?? -1;
  }

  Future<int> _maxItemSortOrder(int listId) async {
    final query = selectOnly(observingListItems)
      ..addColumns([observingListItems.sortOrder.max()])
      ..where(observingListItems.listId.equals(listId));
    final result = await query
        .map((row) => row.read(observingListItems.sortOrder.max()))
        .getSingle();
    return result ?? -1;
  }
}
