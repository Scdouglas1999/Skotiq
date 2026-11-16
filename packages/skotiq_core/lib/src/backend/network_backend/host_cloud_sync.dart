part of '../network_backend.dart';

/// Cloud sync as run by a linked imaging host.
mixin HostCloudSync on NetworkBackendTransport {
  /// Read cloud-backup status from the imaging host. Cloud sync owns the host
  /// database and keyring; a remote controller must never inspect its own
  /// phone-local [SyncService] for this state.
  Future<SyncStatus> getCloudSyncStatus() async {
    final response = await _get(SyncApi.getStatus);
    return SyncStatus.fromJson(response);
  }

  /// Ask the imaging host to create and upload a configuration bundle now.
  Future<SyncPushResult> pushCloudSyncNow() async {
    final response = await _post(SyncApi.pushNow);
    if (response['status'] != 'pushed') {
      throw const FormatException(
        'POST /api/sync/push returned no pushed status',
      );
    }
    final rawTimestamp = response['timestamp'];
    if (rawTimestamp is! num) {
      throw const FormatException('POST /api/sync/push returned no timestamp');
    }
    return SyncPushResult(
      success: true,
      remotePath: response['remotePath'] as String?,
      sizeBytes: (response['sizeBytes'] as num?)?.toInt(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt()),
    );
  }
}
