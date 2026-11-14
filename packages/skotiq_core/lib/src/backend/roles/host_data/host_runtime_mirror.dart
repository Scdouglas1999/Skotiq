import '../../../models/backend/host_runtime_update.dart';
import '../../../models/backend/image_result.dart';

/// The runtime state a linked imaging host mirrors to its clients, and what a client reports back.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostRuntimeMirror {
  Future<List<HostRuntimeUpdate>> getHostRuntimeState();

  Future<void> reportRuntimeState({
    required String channel,
    required Map<String, dynamic>? value,
    required String origin,
  });

  void invalidateDeviceCache();

  Future<CapturedImageResult?> cameraGetLastImage(
    String deviceId, {
    int? maxWidth,
  });
}
