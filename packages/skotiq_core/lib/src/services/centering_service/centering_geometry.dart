part of '../centering_service.dart';

/// Right ascension returned by the plate solver, in **degrees**, converted
/// to the app-canonical **hours** the rest of the centering pipeline uses.
///
/// `PlateSolveResult.ra` is degrees (the native solver reads FITS `CRVAL1`
/// verbatim and the network host forwards it unchanged). Every other RA in
/// this service is hours: the slew target, the mount sync, `mountState.ra`
/// (ASCOM `RightAscension`) and the `CenteringStatus.solvedRa` contract.
/// Normalising once here is what keeps the offset math, the sync slew and the
/// status display in one unit.
double _solvedRaHours(double solvedRaDegrees) {
  return solvedRaDegrees / 15.0;
}

/// Wrap an RA in **hours** into [0, 24) so an offset correction across 0h
/// stays a legal slew target.
double _normalizedRaHours(double raHours) {
  final wrapped = raHours % 24.0;
  return wrapped < 0 ? wrapped + 24.0 : wrapped;
}

/// Clamp a Dec in **degrees** to the legal [-90, 90] range.
double _clampedDecDegrees(double decDegrees) {
  return decDegrees.clamp(-90.0, 90.0);
}
