import 'package:skotiq_core/skotiq_core.dart';

/// [HostRuntimeMirror] on a linked host.
final class RemoteHostRuntimeMirror implements HostRuntimeMirror {
  RemoteHostRuntimeMirror(this._host);

  final NetworkBackend _host;

  @override
  Future<List<HostRuntimeUpdate>> getHostRuntimeState() =>
      _host.getHostRuntimeState();

  @override
  Future<void> reportRuntimeState({
    required String channel,
    required Map<String, dynamic>? value,
    required String origin,
  }) =>
      _host.reportRuntimeState(channel: channel, value: value, origin: origin);
}
