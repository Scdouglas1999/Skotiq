import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../backend/network_backend.dart';
import '../database/daos/observing_lists_dao.dart';
import '../database/database.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

const _observingListNotProvided = Object();

/// DAO provider for ObservingListsDao.
final observingListsDaoProvider = Provider<ObservingListsDao>((ref) {
  return ObservingListsDao(ref.watch(databaseProvider));
});

/// Reactive stream of all observing lists.
///
/// On a remote SLAVE the local observing-lists tables are never populated — the
/// curated lists live in the HOST DB — so this branches onto the host's
/// `/api/observing-lists` instead of the empty local DAO stream.
final observingListsProvider = StreamProvider<List<ObservingList>>((ref) {
  // The selected list id belongs to one host's database namespace. Clear it
  // as soon as this host-aware stream observes a backend switch, even if no
  // mutation notifier has been constructed yet (simply browsing/selecting a
  // list should not be enough to carry host A's numeric id into host B).
  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    if (previous != null && !identical(previous, next)) {
      ref.read(activeObservingListIdProvider.notifier).state = null;
    }
  });
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteObservingLists(
      () => backend.getObservingLists(),
      listEquals,
    );
  }
  return ref.watch(observingListsDaoProvider).watchAllLists();
});

/// Reactive stream of items in a specific list.
final observingListItemsProvider =
    StreamProvider.family<List<ObservingListItem>, int>((ref, listId) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return _pollRemoteObservingLists(
          () => backend.getObservingListItems(listId),
          listEquals,
        );
      }
      return ref.watch(observingListsDaoProvider).watchItemsForList(listId);
    });

/// Watch catalog IDs across all observing lists (for planetarium markers).
final listedCatalogIdsProvider = StreamProvider<Set<String>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteObservingLists(
      () => backend.getListedCatalogIds(),
      setEquals,
    );
  }
  return ref.watch(observingListsDaoProvider).watchAllListedCatalogIds();
});

/// Watch catalog IDs for the active list only.
final activeListCatalogIdsProvider = StreamProvider<Set<String>>((ref) {
  final activeId = ref.watch(activeObservingListIdProvider);
  if (activeId == null) {
    return const Stream.empty();
  }
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteObservingLists(
      () => backend.getListedCatalogIds(listId: activeId),
      setEquals,
    );
  }
  return ref.watch(observingListsDaoProvider).watchCatalogIdsForList(activeId);
});

/// Currently selected/active observing list ID for the planetarium sidebar.
final activeObservingListIdProvider = StateProvider<int?>((ref) => null);

/// Polls [fetch] every [interval], emitting the first value and thereafter ONLY
/// when the value actually changes (per [unchanged]). The observing-lists
/// tables are not pushed over the event stream, so the slave polls the host the
/// same way `database_provider.dart` polls targets/sessions/images; the
/// change-guard keeps a quiet host from re-emitting an identical payload every
/// tick (which would thrash the planetarium markers and list views).
Stream<T> _pollRemoteObservingLists<T>(
  Future<T> Function() fetch,
  bool Function(T a, T b) unchanged, {
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: fetch,
  unchanged: unchanged,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote observing-list poll failed; retaining last value',
      name: 'ObservingListProvider',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);

/// StateNotifier for managing observing list UI interactions.
final observingListNotifierProvider =
    StateNotifierProvider<ObservingListNotifier, ObservingListUiState>((ref) {
      return ObservingListNotifier(ref);
    });

/// UI state for observing list management.
class ObservingListUiState {
  final bool isSaving;
  final String? statusMessage;
  final String? errorMessage;

  const ObservingListUiState({
    this.isSaving = false,
    this.statusMessage,
    this.errorMessage,
  });

  ObservingListUiState copyWith({
    bool? isSaving,
    Object? statusMessage = _observingListNotProvided,
    Object? errorMessage = _observingListNotProvided,
  }) {
    return ObservingListUiState(
      isSaving: isSaving ?? this.isSaving,
      statusMessage: identical(statusMessage, _observingListNotProvided)
          ? this.statusMessage
          : statusMessage as String?,
      errorMessage: identical(errorMessage, _observingListNotProvided)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

class ObservingListNotifier extends StateNotifier<ObservingListUiState> {
  final Ref ref;
  int _authorityRevision = 0;
  int _activeMutations = 0;
  final Map<int, Future<int?>> _duplicateInFlight = {};

  ObservingListNotifier(this.ref) : super(const ObservingListUiState()) {
    ref.listen(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _resetAuthority(clearActiveList: previous != null);
    });
    ref.listen(observingListsDaoProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        _resetAuthority(clearActiveList: false);
      }
    });
  }

  ObservingListsDao get _dao => ref.read(observingListsDaoProvider);

  void _resetAuthority({required bool clearActiveList}) {
    _authorityRevision++;
    _activeMutations = 0;
    _duplicateInFlight.clear();
    if (mounted) state = const ObservingListUiState();
    if (clearActiveList) {
      ref.read(activeObservingListIdProvider.notifier).state = null;
    }
  }

  ({int revision, SkotiqBackend backend, ObservingListsDao dao})
  _captureAuthority() => (
    revision: _authorityRevision,
    backend: ref.read(backendProvider),
    dao: _dao,
  );

  bool _isCurrentAuthority(
    ({int revision, SkotiqBackend backend, ObservingListsDao dao})
    authority,
  ) {
    return mounted &&
        authority.revision == _authorityRevision &&
        identical(authority.backend, ref.read(backendProvider)) &&
        identical(authority.dao, _dao);
  }

  Future<T> _mutate<T>(
    T staleResult,
    Future<T> Function(
      ({int revision, SkotiqBackend backend, ObservingListsDao dao})
      authority,
    )
    operation,
  ) {
    final authority = _captureAuthority();
    _activeMutations++;
    state = state.copyWith(
      isSaving: true,
      statusMessage: null,
      errorMessage: null,
    );
    return operation(authority)
        .then((result) {
          return _isCurrentAuthority(authority) ? result : staleResult;
        })
        .whenComplete(() {
          if (!_isCurrentAuthority(authority)) return;
          _activeMutations--;
          state = state.copyWith(isSaving: _activeMutations > 0);
        });
  }

  /// Force the remote-aware list/items/marker streams to re-poll the host
  /// immediately after a slave mutation (otherwise the change is invisible
  /// until the next 10s poll tick).
  void _invalidateRemoteReads() {
    ref.invalidate(observingListsProvider);
    ref.invalidate(observingListItemsProvider);
    ref.invalidate(listedCatalogIdsProvider);
    ref.invalidate(activeListCatalogIdsProvider);
  }

  /// Create a new observing list.
  Future<int?> createList({required String name, String? description}) {
    return _mutate<int?>(null, (authority) async {
      try {
        final backend = authority.backend;
        final id = backend is NetworkBackend
            ? await backend.createObservingList(
                name: name,
                description: description,
              )
            : await authority.dao.createList(
                name: name,
                description: description,
              );
        if (!_isCurrentAuthority(authority)) return null;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(statusMessage: 'Created list "$name"');
        return id;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(errorMessage: 'Failed to create list: $e');
        }
        return null;
      }
    });
  }

  /// Create a list and add its first item as one user-facing operation.
  ///
  /// The remote API does not expose a transaction spanning both requests, so
  /// this captures one host transport for the entire operation and removes the
  /// newly-created empty list if the item write fails. Capturing [remote]
  /// before the first await also prevents a connection switch between requests
  /// from creating the list on host A and adding the item to host B.
  Future<int?> createListWithItem({
    required String name,
    String? description,
    required String objectName,
    String? catalogId,
    String? objectType,
    required double ra,
    required double dec,
    double? magnitude,
    double? sizeArcmin,
    String? notes,
  }) {
    return _mutate<int?>(null, (authority) async {
      final backend = authority.backend;
      int? listId;
      try {
        listId = backend is NetworkBackend
            ? await backend.createObservingList(
                name: name,
                description: description,
              )
            : await authority.dao.createList(
                name: name,
                description: description,
              );
        if (!_isCurrentAuthority(authority)) {
          throw StateError('The imaging host changed while creating the list.');
        }
        final itemId = backend is NetworkBackend
            ? await backend.addObservingListItem(
                listId: listId,
                objectName: objectName,
                catalogId: catalogId,
                objectType: objectType,
                ra: ra,
                dec: dec,
                magnitude: magnitude,
                sizeArcmin: sizeArcmin,
                notes: notes,
              )
            : await authority.dao.addItem(
                listId: listId,
                objectName: objectName,
                catalogId: catalogId,
                objectType: objectType,
                ra: ra,
                dec: dec,
                magnitude: magnitude,
                sizeArcmin: sizeArcmin,
                notes: notes,
              );
        if (!_isCurrentAuthority(authority)) return null;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(
          statusMessage: 'Created "$name" and added $objectName',
          errorMessage: null,
        );
        return itemId;
      } catch (error) {
        Object? rollbackError;
        if (listId != null) {
          try {
            if (backend is NetworkBackend) {
              await backend.deleteObservingList(listId);
            } else {
              await authority.dao.deleteList(listId);
            }
          } catch (error) {
            rollbackError = error;
          }
        }
        if (!_isCurrentAuthority(authority)) return null;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(
          errorMessage: rollbackError == null
              ? 'Failed to create list and add target: $error'
              : 'The list was created, but the target could not be added and '
                    'the empty list could not be removed: $error '
                    '(cleanup failed: $rollbackError)',
        );
        return null;
      }
    });
  }

  /// Rename an observing list.
  Future<bool> renameList(int id, String newName) {
    return _mutate<bool>(false, (authority) async {
      try {
        final backend = authority.backend;
        if (backend is NetworkBackend) {
          await backend.updateObservingList(id: id, name: newName);
        } else {
          await authority.dao.updateList(id: id, name: newName);
        }
        if (!_isCurrentAuthority(authority)) return false;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(statusMessage: 'Renamed list to "$newName"');
        return true;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(errorMessage: 'Failed to rename list: $e');
        }
        return false;
      }
    });
  }

  /// Update a list's description.
  Future<bool> updateDescription(int id, String? description) {
    return _mutate<bool>(false, (authority) async {
      try {
        final backend = authority.backend;
        if (backend is NetworkBackend) {
          await backend.updateObservingList(
            id: id,
            description: description,
            setDescription: true,
          );
        } else {
          await authority.dao.updateList(
            id: id,
            description: description,
            clearDescription: description == null,
          );
        }
        if (!_isCurrentAuthority(authority)) return false;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        return true;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(
            errorMessage: 'Failed to update description: $e',
          );
        }
        return false;
      }
    });
  }

  /// Update a list's editable metadata as one operation.
  ///
  /// The settings editor changes name and description together. Keeping that
  /// as one repository mutation avoids reporting a successful rename followed
  /// by a silently failed description write, and [setDescription] on the
  /// remote transport preserves an explicit `null` as "clear this field".
  Future<bool> updateList(int id, {required String name, String? description}) {
    return _mutate<bool>(false, (authority) async {
      try {
        final backend = authority.backend;
        if (backend is NetworkBackend) {
          await backend.updateObservingList(
            id: id,
            name: name,
            description: description,
            setDescription: true,
          );
        } else {
          await authority.dao.updateList(
            id: id,
            name: name,
            description: description,
            clearDescription: description == null,
          );
        }
        if (!_isCurrentAuthority(authority)) return false;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(
          statusMessage: 'Updated list "$name"',
          errorMessage: null,
        );
        return true;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(errorMessage: 'Failed to update list: $e');
        }
        return false;
      }
    });
  }

  /// Delete an observing list.
  Future<bool> deleteList(int id) {
    return _mutate<bool>(false, (authority) async {
      try {
        final backend = authority.backend;
        if (backend is NetworkBackend) {
          await backend.deleteObservingList(id);
        } else {
          await authority.dao.deleteList(id);
        }
        if (!_isCurrentAuthority(authority)) return false;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        if (ref.read(activeObservingListIdProvider) == id) {
          ref.read(activeObservingListIdProvider.notifier).state = null;
        }
        state = state.copyWith(statusMessage: 'List deleted.');
        return true;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(errorMessage: 'Failed to delete list: $e');
        }
        return false;
      }
    });
  }

  /// Duplicate a list and all its items.
  Future<int?> duplicateList(int sourceId) {
    final existing = _duplicateInFlight[sourceId];
    if (existing != null) return existing;
    late final Future<int?> operation;
    operation =
        _mutate<int?>(null, (authority) async {
          try {
            final backend = authority.backend;
            final newId = backend is NetworkBackend
                ? await backend.duplicateObservingList(sourceId)
                : await authority.dao.duplicateList(sourceId);
            if (!_isCurrentAuthority(authority)) return null;
            if (backend is NetworkBackend) _invalidateRemoteReads();
            state = state.copyWith(statusMessage: 'List duplicated.');
            return newId;
          } catch (e) {
            if (_isCurrentAuthority(authority)) {
              state = state.copyWith(
                errorMessage: 'Failed to duplicate list: $e',
              );
            }
            return null;
          }
        }).whenComplete(() {
          if (identical(_duplicateInFlight[sourceId], operation)) {
            _duplicateInFlight.remove(sourceId);
          }
        });
    _duplicateInFlight[sourceId] = operation;
    return operation;
  }

  /// Add an object to a list.
  Future<int?> addItem({
    required int listId,
    required String objectName,
    String? catalogId,
    String? objectType,
    required double ra,
    required double dec,
    double? magnitude,
    double? sizeArcmin,
    String? notes,
  }) {
    return _mutate<int?>(null, (authority) async {
      try {
        final backend = authority.backend;
        final id = backend is NetworkBackend
            ? await backend.addObservingListItem(
                listId: listId,
                objectName: objectName,
                catalogId: catalogId,
                objectType: objectType,
                ra: ra,
                dec: dec,
                magnitude: magnitude,
                sizeArcmin: sizeArcmin,
                notes: notes,
              )
            : await authority.dao.addItem(
                listId: listId,
                objectName: objectName,
                catalogId: catalogId,
                objectType: objectType,
                ra: ra,
                dec: dec,
                magnitude: magnitude,
                sizeArcmin: sizeArcmin,
                notes: notes,
              );
        if (!_isCurrentAuthority(authority)) return null;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(statusMessage: 'Added $objectName to list');
        return id;
      } catch (e) {
        if (!_isCurrentAuthority(authority)) return null;
        // A duplicate is not a failure: the object the user asked for is
        // already where they wanted it. Report it as a neutral STATUS (no
        // errorMessage) so the UI stops showing a red "Failed to add item:
        // Bad state: ..." for an ordinary, harmless action. Callers still get
        // `null` — no row was written — but can tell the two apart because
        // errorMessage stays null on this path.
        final duplicate = _asDuplicateItem(e);
        if (duplicate != null) {
          state = state.copyWith(statusMessage: duplicate, errorMessage: null);
          return null;
        }
        state = state.copyWith(errorMessage: 'Failed to add item: $e');
        return null;
      }
    });
  }

  /// Recognise "this object is already in the list" for both authorities:
  /// the local DAO throws [ObservingListDuplicateItemException]; the host
  /// answers POST /api/observing-lists/items with HTTP 409 carrying the same
  /// sentence. Returns the user-facing sentence, or null if [error] is a
  /// genuine failure.
  String? _asDuplicateItem(Object error) {
    if (error is ObservingListDuplicateItemException) return error.message;
    if (error is ServerError && error.httpStatus == 409) {
      return error.message;
    }
    return null;
  }

  /// Remove an item from a list.
  Future<bool> removeItem(int itemId) {
    return _mutate<bool>(false, (authority) async {
      try {
        final backend = authority.backend;
        if (backend is NetworkBackend) {
          await backend.removeObservingListItem(itemId);
        } else {
          await authority.dao.removeItem(itemId);
        }
        if (!_isCurrentAuthority(authority)) return false;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        state = state.copyWith(statusMessage: 'Item removed from list.');
        return true;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(errorMessage: 'Failed to remove item: $e');
        }
        return false;
      }
    });
  }

  /// Update notes on an item.
  Future<bool> updateItemNotes(int itemId, String? notes) {
    return _mutate<bool>(false, (authority) async {
      try {
        final backend = authority.backend;
        if (backend is NetworkBackend) {
          await backend.updateObservingListItemNotes(itemId, notes);
        } else {
          await authority.dao.updateItemNotes(itemId, notes);
        }
        if (!_isCurrentAuthority(authority)) return false;
        if (backend is NetworkBackend) _invalidateRemoteReads();
        return true;
      } catch (e) {
        if (_isCurrentAuthority(authority)) {
          state = state.copyWith(errorMessage: 'Failed to update notes: $e');
        }
        return false;
      }
    });
  }

  /// Get which lists contain a given catalog ID.
  Future<List<ObservingList>> getListsContaining(String catalogId) async {
    final authority = _captureAuthority();
    final backend = authority.backend;
    final lists = backend is NetworkBackend
        ? await backend.getListsContaining(catalogId)
        : await authority.dao.getListsContaining(catalogId);
    if (!_isCurrentAuthority(authority)) {
      throw StateError('The imaging host changed while loading list matches.');
    }
    return lists;
  }

  /// Clear status/error messages.
  void clearMessages() {
    state = state.copyWith(statusMessage: null, errorMessage: null);
  }
}
