import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';

RunDashboardEvent ev(
  int id,
  String title, {
  String category = 'Guiding',
  String message = '',
  RunDashboardEventSeverity severity = RunDashboardEventSeverity.warning,
}) =>
    RunDashboardEvent(
      eventId: BigInt.from(id),
      time: DateTime(2026, 7, 25, 10, 33, id),
      severity: severity,
      category: category,
      title: title,
      message: message,
      isCritical: false,
    );

void main() {
  test('a lone event keeps a repeat count of 1', () {
    final out = collapseRepeatedEvents([ev(1, 'Guider disconnected')]);
    expect(out, hasLength(1));
    expect(out.single.repeatCount, 1);
  });

  test('adjacent identical events collapse into one counted row', () {
    // The observed defect: one mount unplug produced four identical rows.
    final out = collapseRepeatedEvents([
      ev(4, 'Guider disconnected'),
      ev(3, 'Guider disconnected'),
      ev(2, 'Guider disconnected'),
      ev(1, 'Guider disconnected'),
    ]);
    expect(out, hasLength(1));
    expect(out.single.repeatCount, 4);
  });

  test('the collapsed row keeps the newest occurrence', () {
    final out = collapseRepeatedEvents([
      ev(9, 'Guider disconnected'),
      ev(1, 'Guider disconnected'),
    ]);
    expect(out.single.eventId, BigInt.from(9),
        reason: 'newest identity should survive');
    expect(out.single.time.second, 9);
  });

  test('collapsing frees slots so other events survive the limit', () {
    final collapsed = collapseRepeatedEvents([
      ev(5, 'Guider disconnected'),
      ev(4, 'Guider disconnected'),
      ev(3, 'Guider disconnected'),
      ev(2, 'Guider disconnected'),
      ev(1, 'Device error', category: 'Equipment', message: 'Mount lost'),
    ]).take(5).toList();
    expect(collapsed, hasLength(2));
    expect(collapsed.last.title, 'Device error',
        reason: 'the event naming the real cause must not be evicted');
  });

  test('a different event breaks the run', () {
    final out = collapseRepeatedEvents([
      ev(3, 'Guider disconnected'),
      ev(2, 'Settled'),
      ev(1, 'Guider disconnected'),
    ]);
    expect(out.map((e) => e.title).toList(),
        ['Guider disconnected', 'Settled', 'Guider disconnected']);
    expect(out.every((e) => e.repeatCount == 1), isTrue);
  });

  test('same title but different detail or severity does not collapse', () {
    final byMessage = collapseRepeatedEvents([
      ev(2, 'Device error', message: 'Mount lost'),
      ev(1, 'Device error', message: 'Camera lost'),
    ]);
    expect(byMessage, hasLength(2),
        reason: 'different details are different information');

    final bySeverity = collapseRepeatedEvents([
      ev(2, 'Guiding stopped', severity: RunDashboardEventSeverity.critical),
      ev(1, 'Guiding stopped', severity: RunDashboardEventSeverity.info),
    ]);
    expect(bySeverity, hasLength(2));
  });

  test('an empty feed collapses to nothing', () {
    expect(collapseRepeatedEvents(const []), isEmpty);
  });
}
