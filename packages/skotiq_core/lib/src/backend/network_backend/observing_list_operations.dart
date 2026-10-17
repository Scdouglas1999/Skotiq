part of '../network_backend.dart';

/// Remote-client access to the host's observing-lists subsystem
/// (`observing_lists`, `observing_list_items`).
///
/// On a slave these tables live ONLY in the host DB — the slave's local SQLite
/// is empty — so the planetarium Lists tab, the object-info "add to list"
/// picker, the planner candidate list, the Settings > Observing Lists screen,
/// and the star-chart list markers all read nothing. Worse, any list/item the
/// remote user creates would land in the slave's throwaway local DB instead of
/// the master.
///
/// These methods mirror the host's rows over REST and route slave mutations to
/// the host so they persist on the master. They are NOT part of the abstract
/// [SkotiqBackend] surface — only a slave calls them, behind an
/// `is NetworkBackend` branch in the corresponding provider/notifier.
mixin _NetworkBackendObservingListOperations on _NetworkBackendTransport {
  // Reads

  /// GET /api/observing-lists — every observing list on the host, ordered by
  /// sortOrder.
  Future<List<ObservingList>> getObservingLists() async {
    final response = await _get('observing-lists');
    return _observingListsFrom(response, 'lists', ObservingList.fromJson);
  }

  /// GET /api/observing-lists/items?listId= — the items in one list.
  Future<List<ObservingListItem>> getObservingListItems(int listId) async {
    final response = await _get('observing-lists/items', {
      'listId': listId.toString(),
    });
    return _observingListsFrom(response, 'items', ObservingListItem.fromJson);
  }

  /// GET /api/observing-lists/listed-catalog-ids — distinct catalog ids across
  /// all lists, or (with [listId]) for one list. Drives the planetarium
  /// star-chart list markers.
  Future<Set<String>> getListedCatalogIds({int? listId}) async {
    final response = await _get('observing-lists/listed-catalog-ids', {
      if (listId != null) 'listId': listId.toString(),
    });
    final raw = response['catalogIds'];
    if (raw is! List) {
      throw const FormatException(
        'GET /api/observing-lists/listed-catalog-ids returned no '
        '`catalogIds` list',
      );
    }
    final catalogIds = <String>{};
    for (final value in raw) {
      if (value is! String) {
        throw const FormatException(
          'GET /api/observing-lists/listed-catalog-ids returned a '
          'non-string catalog ID',
        );
      }
      catalogIds.add(value);
    }
    return catalogIds;
  }

  /// GET /api/observing-lists/containing?catalogId= — which lists contain a
  /// given catalog id (drives the per-object "in N lists" membership badge).
  Future<List<ObservingList>> getListsContaining(String catalogId) async {
    final response = await _get('observing-lists/containing', {
      'catalogId': catalogId,
    });
    return _observingListsFrom(response, 'lists', ObservingList.fromJson);
  }

  /// Parse a `{key: [...]}` envelope of Drift JSON rows. Local to this mixin
  /// because the shared `_listFrom` in the planning-data mixin is file-private
  /// to that part and not visible here.
  List<T> _observingListsFrom<T>(
    Map<String, dynamic> response,
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    return _rowsFromJson(response[key], fromJson);
  }

  // Writes (slave mutations persist on the master, not the local DB)

  /// POST /api/observing-lists — create a list on the host; returns its id.
  Future<int> createObservingList({
    required String name,
    String? description,
  }) async {
    final response = await _post('observing-lists', {
      'name': name,
      if (description != null) 'description': description,
    });
    return _requiredObservingListId(response, 'POST /api/observing-lists');
  }

  /// POST /api/observing-lists/update — rename / re-describe a list on the host.
  Future<void> updateObservingList({
    required int id,
    String? name,
    String? description,
    bool setDescription = false,
  }) async {
    await _post('observing-lists/update', {
      'id': id,
      if (name != null) 'name': name,
      if (setDescription) 'description': description,
    });
  }

  /// DELETE /api/observing-lists?id= — delete a list (cascades items) on host.
  Future<void> deleteObservingList(int id) async {
    await _delete('observing-lists?id=$id');
  }

  /// POST /api/observing-lists/duplicate — duplicate a list + its items on the
  /// host; returns the new list's id.
  Future<int> duplicateObservingList(int sourceId) async {
    final response = await _post('observing-lists/duplicate', {
      'sourceId': sourceId,
    });
    return _requiredObservingListId(
      response,
      'POST /api/observing-lists/duplicate',
    );
  }

  /// POST /api/observing-lists/items — add an item to a list on the host;
  /// returns the new item's id.
  Future<int> addObservingListItem({
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
    final response = await _post('observing-lists/items', {
      'listId': listId,
      'objectName': objectName,
      if (catalogId != null) 'catalogId': catalogId,
      if (objectType != null) 'objectType': objectType,
      'ra': ra,
      'dec': dec,
      if (magnitude != null) 'magnitude': magnitude,
      if (sizeArcmin != null) 'sizeArcmin': sizeArcmin,
      if (notes != null) 'notes': notes,
    });
    return _requiredObservingListId(
      response,
      'POST /api/observing-lists/items',
    );
  }

  /// DELETE /api/observing-lists/items?id= — remove an item on the host.
  Future<void> removeObservingListItem(int itemId) async {
    await _delete('observing-lists/items?id=$itemId');
  }

  /// POST /api/observing-lists/items/update-notes — edit an item's notes on the
  /// host.
  Future<void> updateObservingListItemNotes(int itemId, String? notes) async {
    await _post('observing-lists/items/update-notes', {
      'itemId': itemId,
      'notes': notes,
    });
  }

  int _requiredObservingListId(Map<String, dynamic> response, String request) {
    final id = response['id'];
    if (id is! num) {
      throw FormatException('$request returned no numeric `id` field');
    }
    return id.toInt();
  }
}
