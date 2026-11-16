part of '../network_backend.dart';

/// The runtime state a linked imaging host mirrors to its clients, and what a client reports back.
mixin HostRuntimeMirror on NetworkBackendTransport {
  Future<CapturedImageResult?> cameraGetLastImage(
    String deviceId, {
    int? maxWidth,
  });

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
}
