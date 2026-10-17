import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as ns_events;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// An event's declared severity is authoritative — payload-type classification
/// must never escalate past it.
///
/// Observed live on a completely healthy 10-frame dark run: the top row of the
/// Recent Events panel read
///
///   [!] Sequencer   Sequencer error   x2   13:26:45
///       Runtime config updated: conditions_score
///
/// `conditions_score` is an internal housekeeping tick emitted roughly every 30
/// seconds with Info severity, but it travelled on the `SequencerEvent.error`
/// payload, and the dashboard derived criticality from the PAYLOAD type. So a
/// routine tick rendered as a critical Sequencer error, every 30s, in a
/// five-row panel — crowding out the events that mattered.
///
/// The native side no longer emits that event at all (it is logged instead), and
/// this guard keeps the class of bug from returning through any other reused
/// payload.
ns_events.SkotiqEvent _event({
  required ns_events.EventSeverity severity,
  String message = 'Runtime config updated: conditions_score',
}) =>
    ns_events.SkotiqEvent(
      eventId: BigInt.from(1),
      timestamp: DateTime(2026, 7, 25, 13, 26, 45).millisecondsSinceEpoch,
      severity: severity,
      category: ns_events.EventCategory.sequencer,
      payload: ns_events.EventPayload.sequencer(
        ns_events.SequencerEvent.error(message: message),
      ),
    );

List<RunDashboardEvent> _dashboardEvents(
  List<ns_events.SkotiqEvent> history,
) {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  // Pushing through the notifier is how the live app populates history.
  for (final event in history) {
    container.read(eventHistoryProvider.notifier).addEvent(event);
  }
  return container.read(runDashboardRecentEventsProvider(5));
}

void main() {
  test('an Info event on the error payload is NOT critical', () {
    final out = _dashboardEvents([
      _event(severity: ns_events.EventSeverity.info),
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
      _event(severity: ns_events.EventSeverity.warning),
    ]);

    expect(out.single.isCritical, isFalse);
    expect(out.single.severity, RunDashboardEventSeverity.warning);
  });

  test('a genuine Error event IS still critical', () {
    // The guard must not blunt real errors — this is the case the payload
    // classification exists for.
    final out = _dashboardEvents([
      _event(
        severity: ns_events.EventSeverity.error,
        message: 'Camera disconnected mid-exposure',
      ),
    ]);

    expect(out.single.isCritical, isTrue);
    expect(out.single.severity, RunDashboardEventSeverity.critical);
  });

  test('a Critical event IS still critical', () {
    final out = _dashboardEvents([
      _event(
        severity: ns_events.EventSeverity.critical,
        message: 'Mount hit a limit',
      ),
    ]);

    expect(out.single.isCritical, isTrue);
    expect(out.single.severity, RunDashboardEventSeverity.critical);
  });
}
