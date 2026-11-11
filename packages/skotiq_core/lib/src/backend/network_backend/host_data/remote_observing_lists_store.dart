import 'package:flutter/foundation.dart' show listEquals, setEquals;

import '../../../database/database.dart' show ObservingList, ObservingListItem;
import '../../network_backend.dart';
import '../../roles/host_data/observing_lists_store.dart';
import 'host_poll.dart';

/// Observing lists on a linked host. The host does not push list changes, so
/// reads poll; this client's own writes refresh the reads at once.
final class RemoteObservingListsStore implements ObservingListsStore {
  RemoteObservingListsStore(this._host);

  final NetworkBackend _host;
  final _poll = HostPoll('observing lists');

  @override
  Stream<List<ObservingList>> watchAllLists() =>
      _poll.watch(_host.getObservingLists, listEquals);

  @override
  Stream<List<ObservingListItem>> watchItemsForList(int listId) =>
      _poll.watch(() => _host.getObservingListItems(listId), listEquals);

  @override
  Stream<Set<String>> watchAllListedCatalogIds() =>
      _poll.watch(_host.getListedCatalogIds, setEquals);

  @override
  Stream<Set<String>> watchCatalogIdsForList(int listId) =>
      _poll.watch(() => _host.getListedCatalogIds(listId: listId), setEquals);

  @override
  Future<List<ObservingList>> getListsContaining(String catalogId) =>
      _host.getListsContaining(catalogId);

  @override
  Future<int> createList({required String name, String? description}) =>
      _changing(
        () => _host.createObservingList(name: name, description: description),
      );

  @override
  Future<void> updateList({
    required int id,
    String? name,
    String? description,
    bool clearDescription = false,
  }) => _changing(
    () => _host.updateObservingList(
      id: id,
      name: name,
      description: description,
      // The wire needs to be told when a null description means "clear it".
      setDescription: description != null || clearDescription,
    ),
  );

  @override
  Future<void> deleteList(int id) =>
      _changing(() => _host.deleteObservingList(id));

  @override
  Future<int> duplicateList(int sourceListId) =>
      _changing(() => _host.duplicateObservingList(sourceListId));

  @override
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
  }) => _changing(
    () => _host.addObservingListItem(
      listId: listId,
      objectName: objectName,
      catalogId: catalogId,
      objectType: objectType,
      ra: ra,
      dec: dec,
      magnitude: magnitude,
      sizeArcmin: sizeArcmin,
      notes: notes,
    ),
  );

  @override
  Future<void> removeItem(int itemId) =>
      _changing(() => _host.removeObservingListItem(itemId));

  @override
  Future<void> updateItemNotes(int itemId, String? notes) =>
      _changing(() => _host.updateObservingListItemNotes(itemId, notes));

  /// Runs a write, then refreshes the polled reads whether it succeeded or
  /// not: a failed write may still have changed the host (a create that timed
  /// out after the host committed it).
  Future<T> _changing<T>(Future<T> Function() write) async {
    try {
      return await write();
    } finally {
      _poll.refresh();
    }
  }
}
