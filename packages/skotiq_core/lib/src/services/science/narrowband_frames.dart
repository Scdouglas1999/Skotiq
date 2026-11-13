import '../../database/database.dart' show DbCapturedImage;
import '../../models/imaging/frame_type_record.dart';

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
  final hAlpha = _latestNamed(lights, const {
    'ha',
    'halpha',
    'h-alpha',
    'h alpha',
  });
  final oiii = _latestNamed(lights, const {'oiii', 'o3'});
  final sii = _latestNamed(lights, const {'sii', 's2'});
  if (hAlpha == null || oiii == null || sii == null) return null;
  return (hAlpha: hAlpha, oiii: oiii, sii: sii);
}

DbCapturedImage? _latestNamed(List<DbCapturedImage> images, Set<String> names) {
  DbCapturedImage? latest;
  for (final image in images) {
    final filter = (image.filter ?? '').toLowerCase().trim();
    // The name alone or as a whole word, so "Shah" is not H-alpha.
    final named = names.any(
      (name) =>
          filter == name ||
          RegExp(
            '(?:^|[\\s_-])${RegExp.escape(name)}(?:[\\s_-]|\$)',
          ).hasMatch(filter),
    );
    if (!named) continue;
    if (latest == null || image.capturedAt.isAfter(latest.capturedAt)) {
      latest = image;
    }
  }
  return latest;
}
