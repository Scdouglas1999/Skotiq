part of '../network_backend.dart';

/// Runtime state the host shares with linked clients (`/api/runtime/state`).
///
/// The same values also arrive live as `HostRuntimeState` events; this is the
/// fetch a client makes on connect and reconnect, and the path its own results
/// take to the host.
mixin _NetworkBackendRuntimeMirrorOperations on _NetworkBackendTransport {
  /// The host's latest value of every runtime channel.
  Future<List<HostRuntimeUpdate>> getHostRuntimeState() async {
    final response = await _get(RuntimeStateApi.getState);
    final raw = response['updates'];
    if (raw is! List) {
      throw const FormatException('runtime/state has no updates list');
    }
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
  /// oldest first.
  Future<List<SkotiqEvent>> getHostRecentEvents({int limit = 100}) async {
    final response = await _get(
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

  /// What the host's Tonight has gathered tonight from live events: guide
  /// steps, autofocus runs, dithers, flips, lost stars, recent solves and the
  /// cooler history.
  Future<Map<String, dynamic>> getHostNightHistory() =>
      _get(RuntimeStateApi.nightHistory);

  /// Send a value this client computed for [channel] to the host.
  Future<void> reportRuntimeState({
    required String channel,
    required Map<String, dynamic>? value,
    required String origin,
  }) async {
    await _post(
      RuntimeStateApi.report,
      body: {'channel': channel, 'value': value, 'origin': origin},
      maxAttempts: 1,
    );
  }

  /// Start the manual Loop on the host with [request] (see
  /// [manualLoopRequestJson]). The loop runs on the host; its progress comes
  /// back on the `manualLoop` runtime channel.
  Future<void> startHostManualLoop(Map<String, dynamic> request) async {
    await _post(RuntimeStateApi.startManualLoop, body: request, maxAttempts: 1);
  }

  /// Stop the host's manual Loop, whichever window started it.
  Future<void> stopHostManualLoop() async {
    await _post(RuntimeStateApi.stopManualLoop, body: const {}, maxAttempts: 1);
  }
}
