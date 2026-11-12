import '../../network_backend.dart';

/// The software version of a linked imaging host and its update flow.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostUpdates {
  Future<List<String>> abortUpdate();

  Future<RemoteJob> applyUpdate();

  Future<RemoteJob> checkForUpdate({String? channel});

  Future<void> discardStagedUpdate();

  Future<RemoteJob> downloadUpdate();

  Future<RemoteVersionInfo> getSystemVersion();

  Future<RemoteUpdateStatus> getUpdateStatus();

  Future<RemoteJob> rollbackUpdate();
}
