/// Stand-ins Smart Night plans with for a camera noise figure that no
/// reading, user entry or published specification supplies. Chosen to be
/// conservative rather than typical: a planning estimate that flatters the rig
/// produces sub-exposures that clip. A pixel size has no stand-in; without one
/// Smart Night refuses to plan.
abstract final class UnknownCameraFigures {
  static const double readNoiseE = 3.5;
  static const double fullWellE = 18000;
  static const double qePeak = 0.65;

  /// The planning-estimate rig's pitch, used only before an exposure context
  /// exists (session optimizer, mosaic defaults).
  static const double pixelSizeMicrons = 3.76;
}
