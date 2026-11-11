import 'package:skotiq_core/skotiq_core.dart';

/// The file system of a linked imaging host, as far as a client may ask about it.
abstract interface class HostFiles {
  Future<Map<String, dynamic>> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
  });

  /// `GET /api/system/disk-space` — the HOST's capture-directory disk
  /// telemetry. Deliberately not part of [SkotiqBackend]: local backends
  /// sample their own filesystem; only remote clients need the wire hop
  /// (the host's capture path does not exist on the phone's filesystem).
  /// Returns `null` when the host has no capture directory configured.
  Future<DiskSpaceInfo?> getHostCaptureDiskSpace();
}
