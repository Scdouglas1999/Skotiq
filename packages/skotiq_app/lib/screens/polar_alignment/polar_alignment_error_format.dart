import 'package:flutter/painting.dart' show Color;
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

/// How a polar-axis error reads against the alignment target.
enum PolarErrorTone { onTarget, close, far }

/// Grades [errorArcsec] (its magnitude) against [targetArcsec]: under the
/// target is on target, under twice the target is close, beyond is far.
/// With [inclusive] an error equal to a bound falls in the better band.
PolarErrorTone polarErrorTone(
  double errorArcsec,
  double targetArcsec, {
  bool inclusive = false,
}) {
  final error = errorArcsec.abs();
  bool within(double bound) => inclusive ? error <= bound : error < bound;
  if (within(targetArcsec)) return PolarErrorTone.onTarget;
  if (within(2 * targetArcsec)) return PolarErrorTone.close;
  return PolarErrorTone.far;
}

/// The color of a [PolarErrorTone].
Color polarErrorToneColor(SkotiqColors colors, PolarErrorTone tone) =>
    switch (tone) {
      PolarErrorTone.onTarget => colors.success,
      PolarErrorTone.close => colors.warning,
      PolarErrorTone.far => colors.error,
    };
