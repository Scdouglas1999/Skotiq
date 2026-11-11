
/// Pointing requests a client sends to a linked imaging host.
abstract interface class HostPointing {
  /// Push a framing target to the imaging host (Plan Tonight handoff).
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  });

  /// Slew to target coordinates
  Future<void> slewToTarget(double ra, double dec);
}
