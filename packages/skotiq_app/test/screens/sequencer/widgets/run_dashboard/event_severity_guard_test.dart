import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as sk_events;
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// An event's declared severity is authoritative — payload-type classification
/// must never escalate past it.
///
/// A payload type is reused across severities (an Info-severity housekeeping
/// tick can travel on the `SequencerEvent.error` payload), so deriving
/// criticality from the PAYLOAD type would render routine ticks as critical
/// Sequencer errors.
sk_events.SkotiqEvent _event({
  required sk_events.EventSeverity severity,
  String message = 'Runtime config updated: conditions_score',
}) =>
    sk_events.SkotiqEvent(
      eventId: BigInt.from(1),
      timestamp: DateTime(2026, 7, 25, 13, 26, 45).millisecondsSinceEpoch,
      severity: severity,
      category: sk_events.EventCategory.sequencer,
      payload: sk_events.EventPayload.sequencer(
        sk_events.SequencerEvent.error(
          message: message,
          kind: severity == sk_events.EventSeverity.error ||
                  severity == sk_events.EventSeverity.critical
              ? sk_events.SequencerErrorKind.stepFailed
              : sk_events.SequencerErrorKind.advisory,
        ),
      ),
    );

List<RunDashboardEvent> _dashboardEvents(
  List<sk_events.SkotiqEvent> history,
) {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  // Pushing through the notifier is how the live app populates history.
  for (final event in history) {
    container.read(eventHistoryProvider.notifier).addEvent(event);
  }
  return runDashboardFeedRows(container.read(eventHistoryProvider))
      .take(5)
      .toList();
}

void main() {
  test('an Info event on the error payload is NOT critical', () {
    final out = _dashboardEvents([
      _event(severity: sk_events.EventSeverity.info),
    ]);

    expect(out, hasLength(1));
    expect(
      out.single.isCritical,
      isFalse,
      reason: 'a housekeeping tick must not read as a critical error',
    );
    expect(out.single.severity, RunDashboardEventSeverity.info);
  });

  test('a Warning event on the error payload stays a warning', () {
    final out = _dashboardEvents([
      _event(severity: sk_events.EventSeverity.warning),
    ]);

    expect(out.single.isCritical, isFalse);
    expect(out.single.severity, RunDashboardEventSeverity.warning);
  });

  test('a genuine Error event IS still critical', () {
    // The guard must not blunt real errors — this is the case the payload
    // classification exists for.
    final out = _dashboardEvents([
      _event(
        severity: sk_events.EventSeverity.error,
        message: 'Camera disconnected mid-exposure',
      ),
    ]);

    expect(out.single.isCritical, isTrue);
    expect(out.single.severity, RunDashboardEventSeverity.critical);
  });

  test('a Critical event IS still critical', () {
    final out = _dashboardEvents([
      _event(
        severity: sk_events.EventSeverity.critical,
        message: 'Mount hit a limit',
      ),
    ]);

    expect(out.single.isCritical, isTrue);
    expect(out.single.severity, RunDashboardEventSeverity.critical);
  });
}
