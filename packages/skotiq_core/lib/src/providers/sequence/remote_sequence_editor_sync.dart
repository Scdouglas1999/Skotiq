import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../backend/skotiq_backend.dart';
import '../../models/sequence/sequence_models.dart';
import '../../services/logging_service.dart';
import '../../services/remote_sequence_editor_sync_lifecycle.dart';
import '../../services/sequence_file_service.dart';
import '../../services/sequence_repository.dart';
import '../backend_provider.dart';
import '../sequence_provider.dart';

const _logSource = 'RemoteSequenceEditorSync';

/// Debounce window for pushing in-editor sequence changes to a remote host.
const remoteSequenceAutoSaveDebounce = Duration(milliseconds: 1500);

/// Debounced auto-save of the in-editor sequence to a remote imaging host.
///
/// Mobile/tablet companions edit in memory; this provider pushes changes to the
/// host via [SequenceRepository.saveSequence] (NetworkBackend `save-full`).
final remoteSequenceEditorSyncProvider = Provider<void>((ref) {
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
    if (backend is! NetworkBackend) return;

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

  late final RemoteSequencePreSwapFlush preSwapFlush;
  preSwapFlush = (outgoingBackend, {required requireSuccess}) async {
    if (isDisposed || outgoingBackend is! NetworkBackend) return;
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
    debounce?.cancel();
    debounce = null;
    RemoteSequenceEditorSyncLifecycle.unregister(preSwapFlush);
  });

  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    if (next is! NetworkBackend) {
      debounce?.cancel();
      debounce = null;
    }
  });

  ref.listen<Sequence?>(currentSequenceProvider, (previous, next) {
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend) return;
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
  required NetworkBackend backend,
  required String reason,
  required bool Function() isActive,
}) async {
  final editor = ref.read(currentSequenceProvider.notifier);
  if (!editor.isDirty) return true;
  if (!ref.read(canEditSequenceProvider)) return true;

  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) return true;

  final logger = ref.read(loggingServiceProvider);
  final repository = SequenceRepository.remote(
    backend,
    ref.read(sequenceFileServiceProvider),
  );

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
