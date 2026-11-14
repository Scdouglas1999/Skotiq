import '../../../database/database.dart' show ObservingList, ObservingListItem;

/// The observing lists kept in the imaging host's database.
///
/// Thrown errors are the implementation's own: adding an object that is
/// already in a list fails with `ObservingListDuplicateItemException` locally
/// and with a 409 `ServerError` from a remote host.
abstract interface class ObservingListsStore {
  Stream<List<ObservingList>> watchAllLists();

  Stream<List<ObservingListItem>> watchItemsForList(int listId);

  /// Catalog ids of every object in any list.
  Stream<Set<String>> watchAllListedCatalogIds();

  Stream<Set<String>> watchCatalogIdsForList(int listId);

  Future<List<ObservingList>> getListsContaining(String catalogId);

  /// Returns the new list's id.
  Future<int> createList({required String name, String? description});

  /// A null [name] or [description] leaves that field alone; pass
  /// [clearDescription] to remove the description.
  Future<void> updateList({
    required int id,
    String? name,
    String? description,
    bool clearDescription = false,
  });

  Future<void> deleteList(int id);

  /// Copies a list and its items. Returns the copy's id.
  Future<int> duplicateList(int sourceListId);

  /// Returns the new item's id.
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
  });

  Future<void> removeItem(int itemId);

  Future<void> updateItemNotes(int itemId, String? notes);
}
