import 'package:skotiq_ui/skotiq_ui.dart';

/// Renders a polar-axis error for a human turning altitude/azimuth bolts.
///
///  * under one arcminute → arcseconds with a decimal (`42.6"`);
///  * under one degree    → arcminutes + arcseconds (`38' 08"`);
///  * beyond that         → degrees + arcminutes + arcseconds (`1° 12' 30"`).
///
/// The sign is preserved (the right-rail az/alt tiles are signed quantities);
/// pass an already-`abs()`-ed value where a separate direction word carries it.
/// A non-finite value renders as an em dash (the kit's unknown marker)
/// rather than `NaN"`.
String formatPolarError(double arcsec) {
  if (!arcsec.isFinite) return kReadoutUnknown;
  final sign = arcsec < 0 ? '-' : '';
  final magnitude = arcsec.abs();

  if (magnitude < 60) return '$sign${magnitude.toStringAsFixed(1)}"';

  // Round to whole arcseconds first, then carry, so 3599.7" reads 1° 00' 00"
  // instead of 0° 59' 60".
  var totalSeconds = magnitude.round();
  final degrees = totalSeconds ~/ 3600;
  totalSeconds -= degrees * 3600;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds - minutes * 60;
  final paddedSeconds = seconds.toString().padLeft(2, '0');

  if (degrees == 0) return "$sign$minutes' $paddedSeconds\"";
  return "$sign$degrees° ${minutes.toString().padLeft(2, '0')}' "
      '$paddedSeconds"';
}

/// How long an All-Sky drift baseline has been accumulating, as a compact
/// `12s` / `4m 12s` / `1h 04m` label.
///
/// The all-sky routine derives the polar error from the drift between a fixed
/// baseline solve and the current one, so this interval is what governs the
/// reading's precision — the same number over 4 seconds and over 4 minutes are
/// not the same measurement.
String formatDriftBaseline(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  if (seconds < 0) return '0s';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
}
