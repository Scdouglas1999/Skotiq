/// The secondary rig of a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostSecondaryRig {
  Future<Map<String, dynamic>> secondaryRigGetStatus();

  Future<void> secondaryRigStart(Map<String, dynamic> config);

  Future<void> secondaryRigStop();
}
