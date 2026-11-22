import '../database.dart' show DbCapturedImage;
import 'frame_type_record.dart';

/// The accepted light frames filed under one filter name.
class AcceptedLights {
  const AcceptedLights({
    required this.filter,
    required this.frames,
    required this.seconds,
  });

  /// `captured_images.filter` as filed, `''` for a frame that names none.
  final String filter;
  final int frames;

  /// Their exposure seconds.
  final double seconds;
}

/// The accepted light frames among [frames], one entry per filter name as
/// filed (`''` for none), in the order each name first appears.
List<AcceptedLights> acceptedLightsAsFiled(Iterable<DbCapturedImage> frames) {
  final counts = <String, (int, double)>{};
  for (final frame in frames) {
    if (!frame.isAcceptedLight) continue;
    final filter = frame.filter ?? '';
    final (n, secs) = counts[filter] ?? (0, 0.0);
    counts[filter] = (n + 1, secs + frame.exposureDuration);
  }
  return [
    for (final MapEntry(key: filter, value: (n, secs)) in counts.entries)
      AcceptedLights(filter: filter, frames: n, seconds: secs),
  ];
}

/// Frame counts by filter name as filed.
Map<String, int> acceptedFramesByFiledFilter(Iterable<AcceptedLights> lights) =>
    {for (final l in lights) l.filter: l.frames};
