part of '../network_backend.dart';

/// Runtime state the host shares with linked clients (`/api/runtime/state`).
///
/// The same values also arrive live as `HostRuntimeState` events; this is the
/// fetch a client makes on connect and reconnect, and the path its own results
/// take to the host.
mixin _NetworkBackendRuntimeMirrorOperations on _NetworkBackendTransport {
  /// The host's latest value of every runtime channel. Empty when the host
  /// predates the endpoint.
  Future<List<HostRuntimeUpdate>> getHostRuntimeState() async {
    final Map<String, dynamic> response;
    try {
      response = await _get('runtime/state');
    } on ServerError catch (e) {
      if (e.httpStatus == 404) return const [];
      rethrow;
    }
    final raw = response['updates'];
    if (raw is! List) return const [];
    final updates = <HostRuntimeUpdate>[];
    for (final item in raw.whereType<Map>()) {
      final update = HostRuntimeUpdate.fromJson(
        Map<String, dynamic>.from(item),
      );
      if (update != null) updates.add(update);
    }
    return updates;
  }

  /// The host's newest log-worthy events from before this client connected,
  /// oldest first. Empty when the host predates the endpoint.
  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100}) async {
    final Map<String, dynamic> response;
    try {
      response = await _get('runtime/recent-events', {'limit': limit});
    } on ServerError catch (e) {
      if (e.httpStatus == 404) return const [];
      rethrow;
    }
    final raw = response['events'];
    if (raw is! List) return const [];
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

  /// Send a value this client computed for [channel] to the host.
  Future<void> reportRuntimeState({
    required String channel,
    required Map<String, dynamic>? value,
    required String origin,
  }) async {
    await _post(
      'runtime/state',
      {'channel': channel, 'value': value, 'origin': origin},
      null,
      1,
    );
  }
}
