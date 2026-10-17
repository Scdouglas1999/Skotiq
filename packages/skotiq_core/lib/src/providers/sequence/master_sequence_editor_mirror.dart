import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/ffi_backend.dart';
import '../../backend/skotiq_backend.dart';
import '../../models/backend/host_mutation_event.dart';
import '../../models/sequence/sequence_models.dart';
import '../../services/logging_service.dart';
import '../../services/sequence_file_service.dart';
import '../backend_provider.dart';
import '../host_mutation_event_provider.dart' show hostMutationEventHubProvider;
import '../settings_provider.dart' show appSettingsProvider, AppSettingsState;
import '../sequence_provider.dart';

const _logSource = 'MasterSequenceEditorMirror';

/// Debounce window for pushing the master's open editor canvas to slaves.
///
/// Shorter than [remoteSequenceAutoSaveDebounce] (1500ms) because canvas
/// mirroring should feel live; long enough to coalesce a burst of node edits
/// into a single WS frame instead of one per keystroke.
const masterEditorMirrorDebounce = Duration(milliseconds: 400);

/// MASTER -> SLAVE mirror of the OPEN sequence-editor canvas.
///
/// The master serializes its working/dirty open sequence onto the WS `/events`
/// stream as [HostMutationEntity.sequenceEditor]; a slave applies it in
/// [applyRemoteSyncEvent], so the slave's sequencer screen shows the master's
/// live canvas rather than only re-saved library sequences.
///
/// Direction: [remoteSequenceEditorSyncProvider] pushes a *slave's* edits UP to
/// the master via REST save-full; this provider is the inverse. They never both
/// run on the same instance — the gate below requires a local [FfiBackend],
/// which a slave (NetworkBackend) never has.
///
/// Emission requires a local [FfiBackend] AND `appSettings.webServerEnabled`,
/// so a plain offline desktop GUI never serializes the editor on every edit.
/// It is suppressed while a run is active (execution state != idle/completed/
/// failed): the canvas is locked mid-run and the run-state mirror in
/// `_applySequencerEvent` owns slave parity.
final masterSequenceEditorMirrorProvider = Provider<void>((ref) {
  Timer? debounce;
  var isDisposed = false;

  ref.onDispose(() {
    isDisposed = true;
    debounce?.cancel();
    debounce = null;
  });

  bool isServingMaster() {
    final backend = ref.read(backendProvider);
    if (backend is! FfiBackend) return false;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    return settings?.webServerEnabled == true;
  }

  void emitCleared() {
    if (isDisposed) return;
    ref
        .read(hostMutationEventHubProvider)
        .publishRemoteOnly(
          entityType: HostMutationEntity.sequenceEditor,
          action: HostMutationAction.cleared,
        );
  }

  void emitSnapshot(Sequence sequence) {
    if (isDisposed) return;
    final editor = ref.read(currentSequenceProvider.notifier);
    final owner = ref.read(activePlanOwnerProvider);
    final Map<String, dynamic> sequenceMap;
    try {
      sequenceMap = ref
          .read(sequenceFileServiceProvider)
          .sequenceToMap(sequence);
    } catch (e, stackTrace) {
      ref
          .read(loggingServiceProvider)
          .error(
            'Failed to serialize open sequence for editor mirror: $e',
            source: _logSource,
            fields: {'stackTrace': '$stackTrace', 'sequence': sequence.name},
          );
      return;
    }

    ref
        .read(hostMutationEventHubProvider)
        .publishRemoteOnly(
          entityType: HostMutationEntity.sequenceEditor,
          action: HostMutationAction.updated,
          entityId: sequence.databaseId?.toString(),
          extra: {
            'sequence': sequenceMap,
            if (sequence.databaseId != null) 'databaseId': sequence.databaseId,
            'isDirty': editor.isDirty,
            // Who owns the host's open plan (manual vs autopilot/Smart Night/
            // mosaic). Additive + backward-compatible: an older slave ignores
            // the field; an older host omits it and the slave defaults to
            // manual via ActivePlanOwnerWire.fromWire.
            'activePlanOwner': owner.wireValue,
          },
        );
  }

  void scheduleEmit() {
    debounce?.cancel();
    debounce = Timer(masterEditorMirrorDebounce, () {
      if (isDisposed) return;
      if (!isServingMaster()) return;
      final sequence = ref.read(currentSequenceProvider);
      if (sequence == null) {
        emitCleared();
        return;
      }
      // Suppress mirroring a frozen canvas mid-run; run-state parity is handled
      // by the executor-event path on the slave.
      if (!ref.read(canEditSequenceProvider)) return;
      emitSnapshot(sequence);
    });
  }

  // Backend may flip (e.g. server toggled on/off); clear any pending push when
  // the instance is no longer a serving master so we don't emit stale frames.
  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    if (next is! FfiBackend) {
      debounce?.cancel();
      debounce = null;
    }
  });

  ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (_, __) {
    if (!isServingMaster()) {
      debounce?.cancel();
      debounce = null;
    }
  });

  ref.listen<Sequence?>(currentSequenceProvider, (previous, next) {
    if (!isServingMaster()) return;
    if (next == null) {
      // Editor closed -> tell slaves to clear immediately (no debounce so a
      // close doesn't lag behind a pending edit frame).
      debounce?.cancel();
      debounce = null;
      emitCleared();
      return;
    }
    scheduleEmit();
  });
});
