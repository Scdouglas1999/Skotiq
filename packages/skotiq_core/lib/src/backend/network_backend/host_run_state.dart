part of '../network_backend.dart';

/// What a linked imaging host is running: the plan this client puts in its
/// editor, its run (to stop it) and its recent events.
final class HostRunState {
  HostRunState(this._host);

  final NetworkBackend _host;

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
  }) async {
    await _host._put(
      SequencerApi.putEditorSequence,
      body: <String, dynamic>{
        'open': sequence != null,
        if (sequence != null) 'sequence': sequence,
        if (databaseId != null) 'databaseId': databaseId,
        'isDirty': isDirty,
      },
    );
  }

  /// Remote-only: stop the host's run through its own executor, keeping or
  /// discarding its resume point as the operator chose.
  Future<void> sequencerStopOnHost({required bool preserveCheckpoint}) async {
    await _host._post(
      SequencerApi.stop,
      body: <String, dynamic>{'preserveCheckpoint': preserveCheckpoint},
    );
  }

  /// The host's newest log-worthy events from before this client connected,
  /// oldest first.
  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100}) async {
    final response = await _host._get(
      RuntimeStateApi.recentEvents,
      query: {'limit': limit},
    );
    final raw = response['events'];
    if (raw is! List) {
      throw const FormatException('runtime/recent-events has no events list');
    }
    final events = <SkotiqEvent>[];
    for (final item in raw.whereType<Map>()) {
      try {
        events.add(SkotiqEvent.fromWireJson(Map<String, dynamic>.from(item)));
      } on FormatException {
        continue;
      }
    }
    return events;
  }
}
