import '../backend/skotiq_backend.dart';

typedef RemoteSequencePreSwapFlush =
    Future<void> Function(
      SkotiqBackend outgoingBackend, {
      required bool requireSuccess,
    });

/// Bridges backend disposal to remote sequence persistence without creating a
/// Riverpod import cycle.
///
/// The backend notifier calls [prepareForBackendSwap] while the outgoing
/// transport is still alive. The editor-sync provider registers a callback
/// that drains any pending save for that exact backend before it is disposed.
class RemoteSequenceEditorSyncLifecycle {
  RemoteSequenceEditorSyncLifecycle._();

  static final Set<RemoteSequencePreSwapFlush> _flushers = {};

  static void register(RemoteSequencePreSwapFlush flusher) {
    _flushers.add(flusher);
  }

  static void unregister(RemoteSequencePreSwapFlush flusher) {
    _flushers.remove(flusher);
  }

  static Future<void> prepareForBackendSwap(
    SkotiqBackend outgoingBackend, {
    bool requireSuccess = false,
  }) async {
    for (final flusher in List<RemoteSequencePreSwapFlush>.from(_flushers)) {
      await flusher(outgoingBackend, requireSuccess: requireSuccess);
    }
  }
}
