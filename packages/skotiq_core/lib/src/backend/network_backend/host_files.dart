part of '../network_backend.dart';

/// The file system of a linked imaging host: the folders it will write to and
/// the files it can send to this device.
mixin HostFiles on NetworkBackendTransport {
  Future<RemoteDirectoryListing> browseRemoteDirectories({String? path}) async {
    final response = await _get(
      FileSystemApi.browseDirectories,
      query: path == null || path.isEmpty ? null : {'path': path},
    );
    return RemoteDirectoryListing.fromJson(response);
  }

  Future<HostDirectoryVerdict> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
    bool create = false,
  }) async {
    try {
      return HostDirectoryVerdict.fromJson(
        await _post(
          FileSystemApi.validateDirectory,
          body: {
            'path': path,
            'mustExist': mustExist,
            'mustBeWritable': mustBeWritable,
            // Makes the folder first, inside the host's allowed folders.
            if (create) 'create': true,
          },
        ),
      );
    } on ServerError catch (refusal) {
      // A folder outside the host's folders is an answer about the folder.
      if (refusal.code != 'path_not_allowed') rethrow;
      return HostDirectoryVerdict.refused(refusal.message);
    }
  }

  Future<Uint8List> downloadSessionExport(int sessionId, String format) async {
    return _downloadBytes(
      SessionApi.exportSession,
      path: {'sessionId': sessionId, 'format': format},
    );
  }

  /// `GET /api/system/disk-space` — the HOST's capture-directory disk
  /// telemetry. Deliberately not part of [SkotiqBackend]: local backends
  /// sample their own filesystem; only remote clients need the wire hop
  /// (the host's capture path does not exist on the phone's filesystem).
  /// Returns `null` when the host has no capture directory configured.
  Future<DiskSpaceInfo?> getHostCaptureDiskSpace() async {
    final Map<String, dynamic> json;
    try {
      json = await _get(SystemApi.diskSpace);
    } on ServerError catch (refusal) {
      // The host's answer about its folder, rebuilt as the exception a local
      // query throws, so a missing folder reads the same on both sides.
      if (refusal.code != 'disk_query_failed') rethrow;
      final details = refusal.details ?? const <String, dynamic>{};
      throw DiskSpaceException(
        details['path'] as String? ?? '',
        refusal.message,
        refusal,
        DiskSpaceFailureKind.values.asNameMap()[details['kind']] ??
            DiskSpaceFailureKind.queryFailed,
      );
    }
    if (json['configured'] == false) return null;
    return DiskSpaceInfo(
      path: json['path'] as String? ?? '',
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      freeBytes: (json['freeBytes'] as num?)?.toInt() ?? 0,
      sampledAt:
          DateTime.tryParse(json['sampledAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}
