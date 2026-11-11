import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../backend/roles/host_data/observing_lists_store.dart';
import '../backend/skotiq_backend.dart';
import '../database/daos/observing_lists_dao.dart';
import '../database/database.dart';
import '../errors/error_text.dart';
import 'async_scope.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

const _observingListNotProvided = Object();

final observingListsDaoProvider = Provider<ObservingListsDao>((ref) {
  return ObservingListsDao(ref.watch(databaseProvider));
});

/// The observing lists of whichever machine is the imaging host: this
/// process's database, or the linked host's.
final observingListsStoreProvider = Provider<ObservingListsStore>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.observingLists ??
      ref.watch(observingListsDaoProvider),
);

/// Reactive stream of all observing lists.
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
  return ref.watch(observingListsStoreProvider).watchAllLists();
});

/// Reactive stream of items in a specific list.
final observingListItemsProvider =
    StreamProvider.family<List<ObservingListItem>, int>(
      (ref, listId) =>
          ref.watch(observingListsStoreProvider).watchItemsForList(listId),
    );

/// Watch catalog IDs across all observing lists (for planetarium markers).
final listedCatalogIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(observingListsStoreProvider).watchAllListedCatalogIds(),
);

/// Watch catalog IDs for the active list only.
final activeListCatalogIdsProvider = StreamProvider<Set<String>>((ref) {
  final activeId = ref.watch(activeObservingListIdProvider);
  if (activeId == null) {
    return const Stream.empty();
  }
  return ref
      .watch(observingListsStoreProvider)
      .watchCatalogIdsForList(activeId);
});

/// Currently selected/active observing list ID for the planetarium sidebar.
final activeObservingListIdProvider = StateProvider<int?>((ref) => null);

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
  int _activeMutations = 0;
  final Map<int, Future<int?>> _duplicateInFlight = {};

  /// A mutation belongs to the store it started on. The store changes when
  /// the backend or the local database does, which makes every scope begun
  /// before that stale.
  late final AsyncScopes<ObservingListsStore> _scopes = AsyncScopes(
    ref.read,
    observingListsStoreProvider,
    alive: () => mounted,
  );

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

  void _resetAuthority({required bool clearActiveList}) {
    _scopes.cancelAll();
    _activeMutations = 0;
    _duplicateInFlight.clear();
    if (mounted) state = const ObservingListUiState();
    if (clearActiveList) {
      ref.read(activeObservingListIdProvider.notifier).state = null;
    }
  }

  Future<T> _mutate<T>(
    T staleResult,
    Future<T> Function(AsyncScope<ObservingListsStore> scope) operation,
  ) {
    final scope = _scopes.begin();
    _activeMutations++;
    state = state.copyWith(
      isSaving: true,
      statusMessage: null,
      errorMessage: null,
    );
    return operation(
      scope,
    ).then((result) => scope.isCurrent ? result : staleResult).whenComplete(() {
      if (scope.isStale) return;
      _activeMutations--;
      state = state.copyWith(isSaving: _activeMutations > 0);
    });
  }

  Future<int?> createList({required String name, String? description}) {
    return _mutate<int?>(null, (scope) async {
      try {
        final id = await scope.value.createList(
          name: name,
          description: description,
        );
        if (scope.isStale) return null;
        state = state.copyWith(statusMessage: 'Created list "$name"');
        return id;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(errorMessage: 'Failed to create list: ${userFacingError(e)}');
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
    return _mutate<int?>(null, (scope) async {
      int? listId;
      try {
        listId = await scope.value.createList(
          name: name,
          description: description,
        );
        if (scope.isStale) {
          throw StateError('The imaging host changed while creating the list.');
        }
        final itemId = await scope.value.addItem(
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
        if (scope.isStale) return null;
        state = state.copyWith(
          statusMessage: 'Created "$name" and added $objectName',
          errorMessage: null,
        );
        return itemId;
      } catch (error) {
        Object? rollbackError;
        if (listId != null) {
          try {
            await scope.value.deleteList(listId);
          } catch (error) {
            rollbackError = error;
          }
        }
        if (scope.isStale) return null;
        state = state.copyWith(
          errorMessage: rollbackError == null
              ? 'Failed to create list and add target: ${userFacingError(error)}'
              : 'The list was created, but the target could not be added and '
                    'the empty list could not be removed: ${userFacingError(error)} '
                    '(cleanup failed: $rollbackError)',
        );
        return null;
      }
    });
  }

  Future<bool> renameList(int id, String newName) {
    return _mutate<bool>(false, (scope) async {
      try {
        await scope.value.updateList(id: id, name: newName);
        if (scope.isStale) return false;
        state = state.copyWith(statusMessage: 'Renamed list to "$newName"');
        return true;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(errorMessage: 'Failed to rename list: ${userFacingError(e)}');
        }
        return false;
      }
    });
  }

  Future<bool> updateDescription(int id, String? description) {
    return _mutate<bool>(false, (scope) async {
      try {
        await scope.value.updateList(
          id: id,
          description: description,
          clearDescription: description == null,
        );
        if (scope.isStale) return false;
        return true;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(
            errorMessage: 'Failed to update description: ${userFacingError(e)}',
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
    return _mutate<bool>(false, (scope) async {
      try {
        await scope.value.updateList(
          id: id,
          name: name,
          description: description,
          clearDescription: description == null,
        );
        if (scope.isStale) return false;
        state = state.copyWith(
          statusMessage: 'Updated list "$name"',
          errorMessage: null,
        );
        return true;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(errorMessage: 'Failed to update list: ${userFacingError(e)}');
        }
        return false;
      }
    });
  }

  Future<bool> deleteList(int id) {
    return _mutate<bool>(false, (scope) async {
      try {
        await scope.value.deleteList(id);
        if (scope.isStale) return false;
        if (ref.read(activeObservingListIdProvider) == id) {
          ref.read(activeObservingListIdProvider.notifier).state = null;
        }
        state = state.copyWith(statusMessage: 'List deleted.');
        return true;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(errorMessage: 'Failed to delete list: ${userFacingError(e)}');
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
        _mutate<int?>(null, (scope) async {
          try {
            final newId = await scope.value.duplicateList(sourceId);
            if (scope.isStale) return null;
            state = state.copyWith(statusMessage: 'List duplicated.');
            return newId;
          } catch (e) {
            if (scope.isCurrent) {
              state = state.copyWith(
                errorMessage: 'Failed to duplicate list: ${userFacingError(e)}',
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
    return _mutate<int?>(null, (scope) async {
      try {
        final id = await scope.value.addItem(
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
        if (scope.isStale) return null;
        state = state.copyWith(statusMessage: 'Added $objectName to list');
        return id;
      } catch (e) {
        if (scope.isStale) return null;
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
        state = state.copyWith(errorMessage: 'Failed to add item: ${userFacingError(e)}');
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

  Future<bool> removeItem(int itemId) {
    return _mutate<bool>(false, (scope) async {
      try {
        await scope.value.removeItem(itemId);
        if (scope.isStale) return false;
        state = state.copyWith(statusMessage: 'Item removed from list.');
        return true;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(errorMessage: 'Failed to remove item: ${userFacingError(e)}');
        }
        return false;
      }
    });
  }

  Future<bool> updateItemNotes(int itemId, String? notes) {
    return _mutate<bool>(false, (scope) async {
      try {
        await scope.value.updateItemNotes(itemId, notes);
        if (scope.isStale) return false;
        return true;
      } catch (e) {
        if (scope.isCurrent) {
          state = state.copyWith(errorMessage: 'Failed to update notes: ${userFacingError(e)}');
        }
        return false;
      }
    });
  }

  Future<List<ObservingList>> getListsContaining(String catalogId) async {
    final scope = _scopes.begin();
    final lists = await scope.value.getListsContaining(catalogId);
    if (scope.isStale) {
      throw StateError('The imaging host changed while loading list matches.');
    }
    return lists;
  }

  void clearMessages() {
    state = state.copyWith(statusMessage: null, errorMessage: null);
  }
}
