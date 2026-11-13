import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/remote_host.dart';
import '../../backend/skotiq_backend.dart';
import '../../models/sequence/sequence_models.dart';
import '../../services/remote_sequence_editor_sync_lifecycle.dart';
import '../../services/sequence_file_service.dart';
import '../../services/sequence_repository.dart';
import '../backend_provider.dart';
import '../sequence_provider.dart';
import '../logging_service_provider.dart';
import '../sequence_file_service_provider.dart';
import '../sequence_repository_provider.dart';

const _logSource = 'RemoteSequenceEditorSync';

/// Debounce window for pushing in-editor sequence changes to a remote host.
const remoteSequenceAutoSaveDebounce = Duration(milliseconds: 1500);

/// Debounce window for writing this client's open plan into the host's
/// editor. Short, so the host and the other clients follow edits live.
const remoteEditorWriteThroughDebounce = Duration(milliseconds: 400);

/// The serialized form of [sequence], used to tell whether two plans are the
/// same document. Null for no plan or one that cannot be serialized.
String? sequenceFingerprint(SequenceFileService files, Sequence? sequence) {
  if (sequence == null) return null;
  try {
    return jsonEncode(files.sequenceToMap(sequence));
  } catch (_) {
    return null;
  }
}

/// What a remote client knows about the host's open plan, shared by the
/// write-through below and the host-to-client mirror apply.
class RemoteEditorSyncState {
  /// The plan last taken from the host. An editor change to exactly this
  /// object came from the host and is not written back.
  Sequence? appliedFromHost;

  /// The fingerprint of the plan the host holds, as far as this client knows.
  String? hostFingerprint;

  /// The fingerprint of the plan this client last wrote to the host.
  String? lastWrittenFingerprint;

  /// True while an edit made here has not reached the host yet. The host's
  /// plan is not applied over it: this client's write lands after and wins.
  bool writePending = false;

  /// Forget everything about a host, on a backend swap.
  void reset() {
    appliedFromHost = null;
    hostFingerprint = null;
    lastWrittenFingerprint = null;
    writePending = false;
  }
}

/// The remote client's [RemoteEditorSyncState]. Plain state, no listeners.
final remoteEditorSyncStateProvider = Provider<RemoteEditorSyncState>(
  (ref) => RemoteEditorSyncState(),
);

/// Remote-client sync of the open plan with the imaging host.
///
/// Every change the operator makes here (an edit, opening a saved plan, a new
/// plan) is written into the host's editor, so the host runs, mirrors and can
/// save the plan this client shows. The host's own changes come back through
/// the editor mirror (`_applySequenceEditorMirror`); the last writer wins.
///
/// Unsaved edits are also saved to the host's library after a quiet spell
/// via [SequenceRepository.saveSequence] (the host's `save-full`).
final remoteSequenceEditorSyncProvider = Provider<void>((ref) {
  Timer? writeThroughTimer;
  Future<void>? writeInFlight;
  Timer? debounce;
  Future<bool>? saveInFlight;
  var saveAgain = false;
  // Tracks whether the provider has been disposed. Nothing may call
  // `ref.read(...)` from an `onDispose` continuation: the container is already
  // in tear-down and the read throws "Tried to read a provider from a
  // ProviderContainer that was already disposed". That rules out a
  // best-effort final save on dispose — by the time the microtask runs the
  // container is gone and the first read inside flushPending throws. Backend
  // swaps are different: the lifecycle hook below runs while the outgoing
  // transport is alive and the notifier awaits it before disposal.
  var isDisposed = false;

  late Future<void> Function({required String reason, bool drainLatest})
  flushPending;

  void scheduleSave(String reason) {
    debounce?.cancel();
    debounce = Timer(remoteSequenceAutoSaveDebounce, () {
      unawaited(flushPending(reason: reason));
    });
  }

  flushPending = ({required String reason, bool drainLatest = false}) async {
    debounce?.cancel();
    debounce = null;
    if (isDisposed) return;
    if (ref.read(currentSequenceProvider) == null) return;

    final running = saveInFlight;
    if (running != null) {
      saveAgain = true;
      final succeeded = await running;
      if (drainLatest &&
          succeeded &&
          !isDisposed &&
          ref.read(currentSequenceProvider.notifier).isDirty) {
        saveAgain = false;
        await flushPending(reason: '${reason}_latest', drainLatest: true);
      }
      return;
    }

    final backend = ref.read(backendProvider);
    if (backend.remoteHost == null) return;

    final operation = _persistRemoteSequence(
      ref,
      backend: backend,
      reason: reason,
      isActive: () => !isDisposed,
    );
    saveInFlight = operation;
    bool succeeded;
    try {
      succeeded = await operation;
    } finally {
      if (identical(saveInFlight, operation)) {
        saveInFlight = null;
      }
    }

    if (isDisposed) return;
    final editor = ref.read(currentSequenceProvider.notifier);
    final needsFollowUp = succeeded && (saveAgain || editor.isDirty);
    saveAgain = false;
    if (!needsFollowUp) return;

    if (drainLatest) {
      await flushPending(reason: '${reason}_latest', drainLatest: true);
    } else {
      scheduleSave('edit_during_save');
    }
  };

  final syncState = ref.read(remoteEditorSyncStateProvider);

  late Future<void> Function() writeThrough;
  void scheduleWriteThrough() {
    writeThroughTimer?.cancel();
    writeThroughTimer = Timer(remoteEditorWriteThroughDebounce, () {
      unawaited(writeThrough());
    });
  }

  writeThrough = () async {
    writeThroughTimer?.cancel();
    writeThroughTimer = null;
    if (isDisposed) return;
    final inFlight = writeInFlight;
    if (inFlight != null) {
      await inFlight;
      if (!isDisposed && syncState.writePending) scheduleWriteThrough();
      return;
    }
    final backend = ref.read(backendProvider);
    final runState = backend.remoteHost?.runState;
    if (runState == null || !ref.read(canEditSequenceProvider)) {
      syncState.writePending = false;
      return;
    }
    final sequence = ref.read(currentSequenceProvider);
    final files = ref.read(sequenceFileServiceProvider);
    final fingerprint = sequenceFingerprint(files, sequence);
    if (sequence != null && fingerprint == null) {
      syncState.writePending = false;
      return;
    }
    final isDirty = ref.read(currentSequenceProvider.notifier).isDirty;
    final operation = Future<void>.sync(
      () => runState.putOpenEditorSequence(
        sequence == null ? null : files.sequenceToMap(sequence),
        databaseId: sequence?.databaseId,
        isDirty: isDirty,
      ),
    );
    writeInFlight = operation;
    try {
      await operation;
      if (isDisposed || !identical(ref.read(backendProvider), backend)) return;
      syncState.hostFingerprint = fingerprint;
      syncState.lastWrittenFingerprint = fingerprint;
    } catch (e) {
      if (isDisposed) return;
      // Not retried: the host refused (its run holds the plan) or is out of
      // reach, and its next mirror frame shows what it holds.
      ref
          .read(loggingServiceProvider)
          .warning(
            'Could not write the plan to the imaging host: $e',
            source: _logSource,
          );
    } finally {
      if (identical(writeInFlight, operation)) writeInFlight = null;
    }
    if (isDisposed) return;
    if (identical(ref.read(currentSequenceProvider), sequence)) {
      syncState.writePending = false;
    } else {
      scheduleWriteThrough();
    }
  };

  late final RemoteSequencePreSwapFlush preSwapFlush;
  preSwapFlush = (outgoingBackend, {required requireSuccess}) async {
    if (isDisposed || outgoingBackend.remoteHost == null) return;
    if (!identical(ref.read(backendProvider), outgoingBackend)) return;
    await flushPending(reason: 'backend_swap', drainLatest: true);
    if (requireSuccess &&
        !isDisposed &&
        ref.read(currentSequenceProvider.notifier).isDirty) {
      throw StateError(
        'The latest remote sequence changes could not be saved.',
      );
    }
  };
  RemoteSequenceEditorSyncLifecycle.register(preSwapFlush);

  ref.onDispose(() {
    isDisposed = true;
    writeThroughTimer?.cancel();
    writeThroughTimer = null;
    debounce?.cancel();
    debounce = null;
    RemoteSequenceEditorSyncLifecycle.unregister(preSwapFlush);
  });

  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    if (!identical(previous, next)) {
      writeThroughTimer?.cancel();
      writeThroughTimer = null;
      syncState.reset();
    }
    if (next.remoteHost == null) {
      debounce?.cancel();
      debounce = null;
    }
  });

  ref.listen<Sequence?>(currentSequenceProvider, (previous, next) {
    final backend = ref.read(backendProvider);
    if (backend.remoteHost == null) return;
    if (!identical(next, syncState.appliedFromHost) &&
        ref.read(canEditSequenceProvider)) {
      syncState.writePending = true;
      scheduleWriteThrough();
    }
    if (next == null) {
      debounce?.cancel();
      debounce = null;
      return;
    }

    final editor = ref.read(currentSequenceProvider.notifier);
    if (!editor.isDirty) return;
    if (!ref.read(canEditSequenceProvider)) return;

    scheduleSave('debounced_edit');
  });
});

Future<bool> _persistRemoteSequence(
  Ref ref, {
  required SkotiqBackend backend,
  required String reason,
  required bool Function() isActive,
}) async {
  final editor = ref.read(currentSequenceProvider.notifier);
  if (!editor.isDirty) return true;
  if (!ref.read(canEditSequenceProvider)) return true;

  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) return true;

  final logger = ref.read(loggingServiceProvider);
  final repository = ref.read(sequenceRepositoryProvider);

  try {
    final savedId = await repository.saveSequence(sequence);
    if (!isActive()) return true;
    if (!identical(ref.read(backendProvider), backend)) return true;

    final markedClean = editor.applyRemoteSave(
      savedId,
      expectedSnapshot: sequence,
    );
    ref.invalidate(savedSequencesProvider);
    ref.invalidate(savedSequenceSummariesProvider);
    logger.info(
      'Remote sequence auto-save complete ($reason): '
      '"${sequence.name}" id=$savedId (markedClean=$markedClean)',
      source: _logSource,
    );
    return true;
  } catch (e, stackTrace) {
    logger.error(
      'Remote sequence auto-save failed ($reason): $e',
      source: _logSource,
      fields: {'stackTrace': '$stackTrace', 'sequenceName': sequence.name},
    );
    developer.log(
      'Remote sequence auto-save failed: $e',
      name: _logSource,
      level: 1000,
      error: e,
      stackTrace: stackTrace,
    );
    return false;
  }
}
