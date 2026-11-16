import '../frame_header.dart';

/// Why a dark or bias master's [header] shows frames that were not at its
/// set-point, or null when they were or the header cannot tell.
///
/// The master builder writes the mean sensor reading (`CCD-TEMP`), the
/// coldest and warmest (`CCDTMIN`, `CCDTMAX`) and the set-point
/// (`SET-TEMP`). A master is off its set-point when any reading it states is
/// more than [toleranceC] from it; a master written before the extremes were
/// recorded is judged by its mean. A master without a set-point (a camera
/// that does not cool) is never judged.
String? masterOffSetPoint(FrameHeader header, double toleranceC) {
  final setPoint = header.firstNumber(const ['SET-TEMP', 'SET_TEMP']);
  if (setPoint == null) return null;
  final mean = header.firstNumber(const ['CCD-TEMP', 'CCD_TEMP']);
  final coldest = header.number('CCDTMIN') ?? mean;
  final warmest = header.number('CCDTMAX') ?? mean;
  if (coldest == null || warmest == null) return null;
  final worst = [
    (coldest - setPoint).abs(),
    (warmest - setPoint).abs(),
  ].reduce((a, b) => a > b ? a : b);
  if (worst <= toleranceC) return null;
  final read = coldest == warmest
      ? '${_celsius(coldest)} on average'
      : '${_celsius(coldest)} to ${_celsius(warmest)}';
  return 'Built from frames that read $read at a ${_celsius(setPoint)} '
      'set-point, more than ${_celsius(toleranceC)} from it';
}

String _celsius(double value) {
  final rounded = (value * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
  return '$text °C';
}
