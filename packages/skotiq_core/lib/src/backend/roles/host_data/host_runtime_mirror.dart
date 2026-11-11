import 'package:skotiq_core/skotiq_core.dart';

/// The runtime state a linked imaging host mirrors to its clients, and what a client reports back.
abstract interface class HostRuntimeMirror {
  /// The host's latest value of every runtime channel. Empty when the host
  /// predates the endpoint.
  Future<List<HostRuntimeUpdate>> getHostRuntimeState();

  /// Send a value this client computed for [channel] to the host.
  Future<void> reportRuntimeState({
    required String channel,
    required Map<String, dynamic>? value,
    required String origin,
  });
}
