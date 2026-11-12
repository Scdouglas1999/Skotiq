// The Incomplete Sessions prompt read "25h 25m" for an unclosed session from
// the day before (reverify RV-07): its length ran to now, not to its last
// frame.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

void main() {
  test('an unclosed session lasts until its last frame', () {
    final start = DateTime(2026, 11, 1, 12, 42);
    final info = SessionRecoveryInfo(
      sessionId: 1,
      startTime: start,
      stats: SessionStats(
        completedExposures: 40,
        failedExposures: 0,
        totalIntegrationSecs: 400,
        autofocusCount: 0,
        lastUpdated: start.add(const Duration(minutes: 6)),
      ),
    );
    expect(info.duration, const Duration(minutes: 6));
  });
}
