/// Equipment-profile facts only the client of a linked imaging host can state.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostProfiles {
  /// The id the host gave the profile this client saved last, or null when
  /// the last save did not return one.
  String? get lastSavedProfileId;
}
