/// Which client holds control of a linked imaging host, and whether a
/// run is in flight on it.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostControlSession {
  Future<bool> hostRunInFlight();
}
