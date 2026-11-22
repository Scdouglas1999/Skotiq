/// Stand-ins Smart Night plans with for a camera figure that no reading, user
/// entry or published specification supplies. Chosen to be conservative
/// rather than typical: a planning estimate that flatters the rig produces
/// sub-exposures that clip.
abstract final class UnknownCameraFigures {
  static const double readNoiseE = 3.5;
  static const double fullWellE = 18000;
  static const double qePeak = 0.65;

  /// Used by the exposure context only. A plan built from a profile alone
  /// has no pixel-size stand-in and refuses instead.
  static const double pixelSizeMicrons = 3.76;
}
