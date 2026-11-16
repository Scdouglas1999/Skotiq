/// Pointing requests a client sends to a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostPointing {
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  });

  Future<void> slewToTarget(double ra, double dec);

  /// Starts the host's centering on a target; answers the id of the host job
  /// that runs it.
  Future<String> startCentering({
    required double raHours,
    required double decDegrees,
    required int maxAttempts,
    required double accuracyArcsec,
    required double exposureSecs,
    required bool syncMount,
  });
}
