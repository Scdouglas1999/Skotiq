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
import 'package:skotiq_core/skotiq_core_events.dart' as sk;

sk.SkotiqEvent _event(sk.EventPayload payload, sk.EventCategory category) {
  return sk.SkotiqEvent(
    eventId: BigInt.from(1),
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: sk.EventSeverity.info,
    category: category,
    payload: payload,
  );
}

class _FakeHistory extends StateNotifier<List<sk.SkotiqEvent>>
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
              const sk.EventPayload.system(
                sk.SystemEvent.notification(
                  title: 'EventStreamReady',
                  message: 'Event stream subscription is active',
                  level: 'debug',
                ),
              ),
              sk.EventCategory.system,
            ),
            _event(
              sk.EventPayload.equipment(
                sk.EquipmentEvent.heartbeatStarted(
                  deviceType: 'camera',
                  deviceId: 'sim_camera_1',
                  intervalSecs: BigInt.from(5),
                ),
              ),
              sk.EventCategory.equipment,
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
      const sk.EventPayload.system(
        sk.SystemEvent.notification(
          title: 'EventStreamReady',
          message: 'Event stream subscription is active',
          level: 'debug',
        ),
      ),
      sk.EventCategory.system,
    );

    expect(isUserFacingRunEvent(event), isFalse);
  });

  test('heartbeat lifecycle plumbing is not user-facing', () {
    final started = _event(
      sk.EventPayload.equipment(
        sk.EquipmentEvent.heartbeatStarted(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
          intervalSecs: BigInt.from(5),
        ),
      ),
      sk.EventCategory.equipment,
    );
    final stopped = _event(
      const sk.EventPayload.equipment(
        sk.EquipmentEvent.heartbeatStopped(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
      ),
      sk.EventCategory.equipment,
    );

    expect(isUserFacingRunEvent(started), isFalse);
    expect(isUserFacingRunEvent(stopped), isFalse);
  });

  test('a real notification and a real device event still show', () {
    final notification = _event(
      const sk.EventPayload.system(
        sk.SystemEvent.notification(
          title: 'Sequence complete',
          message: 'All targets finished.',
          level: 'info',
        ),
      ),
      sk.EventCategory.system,
    );
    final connected = _event(
      const sk.EventPayload.equipment(
        sk.EquipmentEvent.connected(
          deviceType: 'camera',
          deviceId: 'sim_camera_1',
        ),
      ),
      sk.EventCategory.equipment,
    );

    expect(isUserFacingRunEvent(notification), isTrue);
    expect(isUserFacingRunEvent(connected), isTrue);
  });
}
