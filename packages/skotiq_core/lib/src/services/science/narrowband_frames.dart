import 'package:skotiq_astro/filters.dart';

import '../../database/database.dart' show DbCapturedImage;
import '../../database/rows/frame_type_record.dart';

/// The newest H-alpha, OIII and SII light frames of one session: the frames a
/// session's narrowband line ratios are made from.
typedef NarrowbandFrames = ({
  DbCapturedImage hAlpha,
  DbCapturedImage oiii,
  DbCapturedImage sii,
});

/// What to say when a session lacks one of the three frames.
const lineRatioFramesMissing =
    'Line ratios need an H-alpha, an OIII and an SII light frame from this '
    'session.';

/// The newest light frame per narrowband filter in [images], or null when one
/// of the three is missing.
NarrowbandFrames? latestNarrowbandFrames(Iterable<DbCapturedImage> images) {
  final lights = images.where((image) => image.isLight).toList();
  final hAlpha = _latestThrough(lights, 'HA');
  final oiii = _latestThrough(lights, 'OIII');
  final sii = _latestThrough(lights, 'SII');
  if (hAlpha == null || oiii == null || sii == null) return null;
  return (hAlpha: hAlpha, oiii: oiii, sii: sii);
}

/// The newest of [images] taken through the filter of [band] alone, by the
/// filter-name rule ("Baader Ha 7nm" and "Hydrogen alpha" are Ha).
DbCapturedImage? _latestThrough(List<DbCapturedImage> images, String band) {
  DbCapturedImage? latest;
  for (final image in images) {
    final filter = image.filter;
    if (filter == null || filterIdentity(filter) != band) continue;
    if (latest == null || image.capturedAt.isAfter(latest.capturedAt)) {
      latest = image;
    }
  }
  return latest;
}
