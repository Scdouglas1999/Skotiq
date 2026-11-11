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

