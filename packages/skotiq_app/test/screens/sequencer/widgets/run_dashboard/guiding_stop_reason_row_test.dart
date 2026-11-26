// The night log printed a guiding stop's reason as its wire code:
// "Guiding stopped · run_stopped".
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as be;

be.SkotiqEvent _stop(int id, String? reason) => be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: DateTime.utc(2026, 11, 25, 22, 28, id).millisecondsSinceEpoch,
      severity: be.EventSeverity.info,
      category: be.EventCategory.guiding,
      payload:
          be.EventPayload.guiding(be.GuidingEvent.stopReason(reason: reason)),
    );

void main() {
  test('a guiding stop reads its reason in words', () {
    final rows = runDashboardFeedRows([_stop(1, 'run_stopped')]);
    expect(rows.single.title, 'Guiding stopped because the run was stopped');
    expect(rows.single.message, isEmpty);
  });

  test('a reason this build does not know keeps the plain row', () {
    final rows = runDashboardFeedRows([_stop(1, 'future_reason')]);
    expect(rows.single.title, 'Guiding stopped');
    expect(rows.single.message, 'future_reason');
  });
}
