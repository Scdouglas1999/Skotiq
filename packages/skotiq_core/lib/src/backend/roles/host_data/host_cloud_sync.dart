import 'package:skotiq_core/skotiq_core.dart';

/// Cloud sync as run by a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostCloudSync {
  Future<SyncStatus> getCloudSyncStatus();

  Future<SyncPushResult> pushCloudSyncNow();
}
