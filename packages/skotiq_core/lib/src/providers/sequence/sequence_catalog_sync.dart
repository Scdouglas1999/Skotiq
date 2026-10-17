import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../backend/skotiq_backend.dart';
import '../../models/sequence/sequence_models.dart';
import '../../models/backend/host_mutation_event.dart';
import '../../services/sequence_repository.dart';
import '../backend_provider.dart';
import '../host_mutation_event_provider.dart';
import '../sequence_provider.dart';

const sequenceUpdatedEventType = 'SequenceUpdated';
const _logSource = 'SequenceCatalogSync';

/// Describes a change to the persisted sequence catalog (library / templates).
class SequenceCatalogUpdate {
  final int sequenceId;
  final String action;
  final String? name;
  final bool isTemplate;

  const SequenceCatalogUpdate({
    required this.sequenceId,
    required this.action,
    this.name,
    this.isTemplate = false,
  });

  Map<String, dynamic> toEventData() => {
    'sequenceId': sequenceId,
    'action': action,
    if (name != null) 'name': name,
    'isTemplate': isTemplate,
  };

  SkotiqEvent toSkotiqEvent() => SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.sequencer,
    eventType: sequenceUpdatedEventType,
    data: toEventData(),
  );
}

/// In-process bus so headless API handlers and the desktop GUI share the same
/// ProviderContainer can refresh the library without a WebSocket round-trip.
class SequenceCatalogUpdateBus {
  final _controller = StreamController<SequenceCatalogUpdate>.broadcast();

  Stream<SequenceCatalogUpdate> get stream => _controller.stream;

  void notify(SequenceCatalogUpdate update) {
    if (!_controller.isClosed) {
      _controller.add(update);
    }
  }

  void dispose() {
    _controller.close();
  }
}

final sequenceCatalogUpdateBusProvider = Provider<SequenceCatalogUpdateBus>((
  ref,
) {
  final bus = SequenceCatalogUpdateBus();
  ref.onDispose(bus.dispose);
  return bus;
});

/// Provider for sequences list — loads from local DB or remote host catalog.
final savedSequencesProvider = FutureProvider.autoDispose<List<Sequence>>((
  ref,
) async {
  final repository = ref.watch(sequenceRepositoryProvider);
  return repository.loadAllSequences();
});

/// Lightweight summaries for the sequence library list.
///
/// Prefer this over [savedSequencesProvider] when rendering the library: it is
/// backed by a single grouped query and does NOT hydrate each sequence's full
/// node tree (the N+1 [savedSequencesProvider] incurs). Invalidated alongside
/// [savedSequencesProvider] whenever the catalog changes.
final savedSequenceSummariesProvider =
    FutureProvider.autoDispose<List<SequenceSummary>>((ref) async {
      final repository = ref.watch(sequenceRepositoryProvider);
      return repository.loadSequenceSummaries();
    });

/// Keeps the sequencer library fresh when remote clients mutate sequences.
///
/// * Desktop GUI (local [FfiBackend]): listens to [SequenceCatalogUpdateBus]
///   because the embedded headless API writes through the same container.
/// * Remote companions ([NetworkBackend]): also listens for `SequenceUpdated`
///   on the host WebSocket event stream.
final sequenceLibrarySyncProvider = Provider<void>((ref) {
  StreamSubscription<SequenceCatalogUpdate>? busSub;
  StreamSubscription<SkotiqEvent>? eventSub;

  void invalidateLibrary() {
    ref.invalidate(savedSequencesProvider);
    ref.invalidate(savedSequenceSummariesProvider);
  }

  void onCatalogUpdate(SequenceCatalogUpdate update) {
    invalidateLibrary();
    unawaited(reloadOpenSequenceIfIdle(ref, update.sequenceId));
  }

  void attachBus() {
    busSub?.cancel();
    busSub = ref
        .read(sequenceCatalogUpdateBusProvider)
        .stream
        .listen(onCatalogUpdate);
  }

  void attachBackendEvents(SkotiqBackend backend) {
    eventSub?.cancel();
    eventSub = null;
    if (backend is NetworkBackend) {
      eventSub = backend.eventStream.listen((event) {
        if (event.eventType == sequenceUpdatedEventType) {
          final id = event.data['sequenceId'];
          if (id is int) {
            onCatalogUpdate(
              SequenceCatalogUpdate(sequenceId: id, action: 'updated'),
            );
          } else {
            invalidateLibrary();
          }
          return;
        }
        if (event.eventType == hostStateChangedEventType &&
            event.data['entityType'] == HostMutationEntity.sequence) {
          final entityId = event.data['entityId'] as String?;
          final parsedId = entityId == null ? null : int.tryParse(entityId);
          if (parsedId != null) {
            onCatalogUpdate(
              SequenceCatalogUpdate(sequenceId: parsedId, action: 'updated'),
            );
          } else {
            invalidateLibrary();
          }
        }
      });
    }
  }

  void teardown() {
    busSub?.cancel();
    eventSub?.cancel();
    busSub = null;
    eventSub = null;
  }

  ref.onDispose(teardown);

  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    teardown();
    attachBus();
    attachBackendEvents(next);
  }, fireImmediately: true);
});

/// Notify listeners that the sequence catalog changed (desktop GUI mutations).
void notifySequenceCatalogChanged(
  WidgetRef ref, {
  required int sequenceId,
  required String action,
  String? name,
  bool isTemplate = false,
}) {
  _emitSequenceCatalogUpdate(
    bus: ref.read(sequenceCatalogUpdateBusProvider),
    sequenceId: sequenceId,
    action: action,
    name: name,
    isTemplate: isTemplate,
    publishHostMutation: (mutationAction, extra) {
      publishHostMutationFromRef(
        ref,
        entityType: HostMutationEntity.sequence,
        action: mutationAction,
        entityId: sequenceId.toString(),
        extra: extra,
      );
    },
  );
}

/// Container variant for headless API handlers.
void notifySequenceCatalogChangedFromContainer(
  ProviderContainer container, {
  required int sequenceId,
  required String action,
  String? name,
  bool isTemplate = false,
}) {
  _emitSequenceCatalogUpdate(
    bus: container.read(sequenceCatalogUpdateBusProvider),
    sequenceId: sequenceId,
    action: action,
    name: name,
    isTemplate: isTemplate,
    publishHostMutation: (mutationAction, extra) {
      publishHostMutationFromContainer(
        container,
        entityType: HostMutationEntity.sequence,
        action: mutationAction,
        entityId: sequenceId.toString(),
        extra: extra,
      );
    },
  );
}

void _emitSequenceCatalogUpdate({
  required SequenceCatalogUpdateBus bus,
  required int sequenceId,
  required String action,
  String? name,
  bool isTemplate = false,
  required void Function(String mutationAction, Map<String, dynamic> extra)
  publishHostMutation,
}) {
  bus.notify(
    SequenceCatalogUpdate(
      sequenceId: sequenceId,
      action: action,
      name: name,
      isTemplate: isTemplate,
    ),
  );

  publishHostMutation(_hostMutationActionForCatalogAction(action), {
    if (name != null) 'name': name,
    'isTemplate': isTemplate,
    'catalogAction': action,
  });
}

/// Reload the in-editor sequence when a remote/tablet save touched the same row.
///
/// This is the SAVE-PATH fallback for editor-canvas parity: when the master
/// re-saves the SAME sequence the slave currently has open AND the slave has no
/// unsaved edits, the slave reloads it so the canvas stays in sync. Run-state +
/// library list parity are handled elsewhere (executor events +
/// [sequenceLibrarySyncProvider]).
///
/// LIVE open-canvas mirroring ("the master edits its open sequence, or opens a
/// different one, and the slave's canvas follows in real time") is handled by
/// the dedicated [HostMutationEntity.sequenceEditor] path:
/// `masterSequenceEditorMirrorProvider` serializes the master's working/dirty
/// open sequence and broadcasts it over WS, and `_applySequenceEditorMirror`
/// applies it on the slave. This function remains as the belt-and-suspenders
/// reload for the case where only a persisted save fired; both share the same
/// [isDirty] clobber-guard so a slave operator's unsaved work is never lost.
Future<void> reloadOpenSequenceIfIdle(Ref ref, int sequenceId) async {
  final current = ref.read(currentSequenceProvider);
  if (current?.databaseId != sequenceId) {
    return;
  }

  final editor = ref.read(currentSequenceProvider.notifier);
  if (editor.isDirty) {
    return;
  }

  try {
    final loaded = await ref
        .read(sequenceRepositoryProvider)
        .loadSequence(sequenceId);
    if (loaded != null) {
      editor.loadSequence(loaded, discardUnsaved: true);
    }
  } catch (e, stackTrace) {
    // Library invalidation still ran; editor reload is best-effort.
    developer.log(
      'reloadOpenSequenceIfIdle failed for sequenceId=$sequenceId: $e',
      name: _logSource,
      level: 900,
      error: e,
      stackTrace: stackTrace,
    );
  }
}

String _hostMutationActionForCatalogAction(String action) {
  switch (action) {
    case 'deleted':
      return HostMutationAction.deleted;
    case 'created':
    case 'duplicated':
      return HostMutationAction.created;
    case 'saved':
    case 'updated':
    default:
      return HostMutationAction.updated;
  }
}
