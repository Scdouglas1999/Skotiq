// Small formatters shared by the center column's widgets. Times arrive on
// the operator's clock already (the view models' rule), so these only print.

import 'package:skotiq_astro/format.dart';

/// The thumbnail fallback for a frame whose file is not on this machine (a
/// remote viewer): no path, so the tile shows its placeholder.
const String nightNoLocalFile = '';

/// `Ha 180 s`, `180 s`, `Ha`; null when neither is known.
String? nightFilterExposure(String? filter, double? exposureSecs) {
  final parts = <String>[
    if (filter != null && filter.isNotEmpty) filter,
    if (exposureSecs != null && exposureSecs > 0)
      QuantityFormat.exposure(exposureSecs),
  ];
  return parts.isEmpty ? null : parts.join(' ');
}
