// qa-rig RIG-22 / qa-surfaces S34: the Quick captures bucket read Duration
// "—", and its time axes ran to "3682h54m" for captures spread over months.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/session_elapsed.dart';
import 'package:skotiq_app/screens/analytics/widgets/chart_axis.dart';

void main() {
  test('the quick-capture duration is the span of its captures', () {
    final t0 = DateTime(2026, 11, 2, 11, 48);
    expect(
      captureSpanLabel([t0, t0.add(const Duration(minutes: 16))]),
      '16m',
    );
    expect(
      captureSpanLabel([t0, t0.add(const Duration(days: 153))]),
      '153 days',
    );
  });

  test('a months-long axis is labeled in days', () {
    expect(elapsedAxisLabel(3682 * 3600.0), '153d');
    expect(elapsedAxisLabel(5 * 3600.0), '5h');
  });
}
