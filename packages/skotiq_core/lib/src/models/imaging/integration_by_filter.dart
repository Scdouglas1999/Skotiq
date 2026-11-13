import '../../database/database.dart' show DbCapturedImage;
import 'frame_type_record.dart';

/// Light-frame integration per filter: what the grader kept and what was
/// spent. A frame with no filter counts under [unfiltered].
class IntegrationByFilter {
  const IntegrationByFilter({
    required this.acceptedSecs,
    required this.totalSecs,
  });

  /// The light frames among [frames], summed by filter.
  factory IntegrationByFilter.of(Iterable<DbCapturedImage> frames) {
    final accepted = <String, double>{};
    final total = <String, double>{};
    for (final frame in frames) {
      if (!frame.isLight) continue;
      final filter = frame.filter == null || frame.filter!.isEmpty
          ? unfiltered
          : frame.filter!;
      total[filter] = (total[filter] ?? 0.0) + frame.exposureDuration;
      if (frame.isAccepted) {
        accepted[filter] = (accepted[filter] ?? 0.0) + frame.exposureDuration;
      }
    }
    return IntegrationByFilter(acceptedSecs: accepted, totalSecs: total);
  }

  static const empty = IntegrationByFilter(acceptedSecs: {}, totalSecs: {});

  /// The name frames without a filter are counted under.
  static const unfiltered = 'Unfiltered';

  /// Filter -> accepted light-frame seconds.
  final Map<String, double> acceptedSecs;

  /// Filter -> all light-frame seconds, accepted and rejected.
  final Map<String, double> totalSecs;
}
