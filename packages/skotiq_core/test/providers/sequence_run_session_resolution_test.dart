import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

ImagingSession _session({
  required int id,
  required DateTime start,
  String name = 'M42 run',
  int? sequenceId = 12,
  DateTime? end,
}) {
  return ImagingSession(
    id: id,
    name: name,
    startTime: start,
    endTime: end ?? start.add(const Duration(hours: 2)),
    totalExposures: 0,
    successfulExposures: 0,
    failedExposures: 0,
    totalIntegrationSecs: 0,
    autofocusCount: 0,
    status: 'completed',
    sequenceId: sequenceId,
  );
}

SequenceRun _run(DateTime start) {
  return SequenceRun(
    id: 91,
    sequenceId: 12,
    sequenceName: 'M42 run',
    startedAt: start,
    endedAt: start.add(const Duration(hours: 1)),
    status: 'completed',
    statsJson: '{}',
  );
}

void main() {
  test('zero-frame fallback selects the nearest matching session start', () {
    final start = DateTime.utc(2026, 7, 14, 1);
    final result = resolveSessionIdForSequenceRun(_run(start), [
      _session(id: 4, start: start.subtract(const Duration(minutes: 4))),
      _session(id: 8, start: start.subtract(const Duration(seconds: 2))),
    ]);

    expect(result, 8);
  });

  test('zero-frame fallback refuses unrelated or stale sessions', () {
    final start = DateTime.utc(2026, 7, 14, 1);
    final result = resolveSessionIdForSequenceRun(_run(start), [
      _session(
        id: 1,
        start: start.subtract(const Duration(seconds: 1)),
        sequenceId: 99,
      ),
      _session(
        id: 2,
        start: start.subtract(const Duration(seconds: 1)),
        name: 'Different sequence',
      ),
      _session(id: 3, start: start.subtract(const Duration(minutes: 6))),
    ]);

    expect(result, isNull);
  });
}
