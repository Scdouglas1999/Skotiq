// RECENT EVENTS is what a user reads their night from, so plumbing must not
// fill it.
//
// On a fresh profile the only entry available is
//   System  EventStreamReady  10:23:44 / Event stream subscription is active (debug)
// — a raw internal name and a line that literally ends in "(debug)" — and one
// connect produces five rows stamped the same second:
//   Heartbeat started · Heartbeat stopped · Heartbeat started · Heartbeat
//   stopped · Connected
// Four of the five are monitor plumbing, and because the panel holds five rows
// they evict the events that mean something. Both kinds still reach the
// diagnostics log.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/skotiq_core_events.dart' as ns;

ns.SkotiqEvent _event(ns.EventPayload payload, ns.EventCategory category) {
  return ns.SkotiqEvent(
    eventId: BigInt.from(1),
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: ns.EventSeverity.info,
    category: category,
    payload: payload,
  );
}

class _FakeHistory extends StateNotifier<List<ns.SkotiqEvent>>
    implements EventHistoryNotifier {
  _FakeHistory(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a feed of nothing but plumbing renders as no events at all', () {
    final container = ProviderContainer(
      overrides: [
        eventHistoryProvider.overrideWith(
          (ref) => _FakeHistory([
            _event(
              const ns.EventPayload.system(
                ns.SystemEvent.notification(
                  title: 'EventStreamReady',
                  message: 'Event stream subscription is active',
                  level: 'debug',
                ),
              ),
              ns.EventCategory.system,
            ),
            _event(
              ns.EventPayload.equipment(
                ns.EquipmentEvent.heartbeatStarted(
                  deviceType: 'camera',
                  deviceId: 'sim_camera_1',
                  intervalSecs: BigInt.from(5),
                ),
              ),
              ns.EventCategory.equipment,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(runDashboardRecentEventsProvider(5)), isEmpty);
  });

  test('the debug stream-ready notification is not user-facing', () {
    final event = _event(
      const ns.EventPayload.system(
        ns.SystemEvent.notification(
          title: 'EventStreamReady',
          message: 'Event stream subscription is active',
          level: 'debug',
        ),
      ),
      ns.EventCategory.system,
    );

    expect(isUserFacingRunEvent(event), isFalse);
  });

  test('heartbeat lifecycle plumbing is not user-facing', () {
    final started = _event(
      ns.EventPayload.equipment(
        ns.EquipmentEvent.heartbeatStarted(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
          intervalSecs: BigInt.from(5),
        ),
      ),
      ns.EventCategory.equipment,
    );
    final stopped = _event(
      const ns.EventPayload.equipment(
        ns.EquipmentEvent.heartbeatStopped(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
      ),
      ns.EventCategory.equipment,
    );

    expect(isUserFacingRunEvent(started), isFalse);
    expect(isUserFacingRunEvent(stopped), isFalse);
  });

  test('a real notification and a real device event still show', () {
    final notification = _event(
      const ns.EventPayload.system(
        ns.SystemEvent.notification(
          title: 'Sequence complete',
          message: 'All targets finished.',
          level: 'info',
        ),
      ),
      ns.EventCategory.system,
    );
    final connected = _event(
      const ns.EventPayload.equipment(
        ns.EquipmentEvent.connected(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
      ),
      ns.EventCategory.equipment,
    );

    expect(isUserFacingRunEvent(notification), isTrue);
    expect(isUserFacingRunEvent(connected), isTrue);
  });
}
