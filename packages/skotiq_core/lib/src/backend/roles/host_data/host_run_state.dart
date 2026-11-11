import 'package:skotiq_core/skotiq_core.dart';

/// What a linked imaging host is running: the plan open in its editor, its scheduled start, the end-of-night state and its recent events.
abstract interface class HostRunState {
  /// G2 (remote-only): fetch the master's currently-open editor sequence so a
  /// slave connecting mid-session can seed its sequencer canvas immediately
  /// instead of waiting for the master's next edit-triggered mirror frame.
  ///
  /// Returns the same payload shape the live editor mirror broadcasts over the
  /// WS `/events` stream (`{sequence, databaseId?, isDirty}`), suitable for
  /// feeding straight into `_applySequenceEditorMirror`. Returns `null` when no
  /// sequence is open host-side (`{open: false}`) or the endpoint is missing on
  /// an older headless host. Not part of the abstract backend — only a
  /// NetworkBackend slave ever calls this.
  Future<Map<String, dynamic>?> getOpenEditorSequence();

  /// Remote-only: put this client's open plan into the host's sequence
  /// editor, so the host runs and mirrors the plan the operator sees here.
  ///
  /// [sequence] null closes the host's editor. [isDirty] carries whether the
  /// plan has changes not yet saved to the library. Throws when the host
  /// refuses, for example while its run holds the editor (409).
  Future<void> putOpenEditorSequence(
    Map<String, dynamic>? sequence, {
    int? databaseId,
    required bool isDirty,
  });

  /// Remote-only: stop the host's run through its own executor, keeping or
  /// discarding its resume point as the operator chose.
  Future<void> sequencerStopOnHost({required bool preserveCheckpoint});

  /// Remote-only: the host's end-of-night calibration status.
  Future<EonStatus?> hostEndOfNightStatus();

  /// Remote-only: the host's scheduled start (Start at dark), or null.
  Future<DateTime?> hostScheduledStart();

  /// End a session with the given status.
  Future<void> endSession(int id, {String status = 'completed'});

  /// The host's newest log-worthy events from before this client connected,
  /// oldest first. Empty when the host predates the endpoint.
  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100});

  /// Remote-only: whether the host is warming the camera.
  Future<bool> cameraHostIsWarming();
}
