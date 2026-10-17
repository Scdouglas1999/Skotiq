// Owner decision 2 (2026-08-14): the phone push for a stopped run is restored
// for NON-OPERATOR stops only, at INFO (non-alarm) priority, carrying the real
// cause. The operator's own press stays silent — they are standing at the
// keyboard that issued it.
//
// The stop's true author is on the wire (the closing chain put it there):
//
//   * `DecisionLogged` category `manual_intervention`, summary starting
//     "Operator: stop"                                   -> the operator
//   * `DecisionLogged` category `system_event`, summary "Autopilot: stop"
//                                                        -> the autopilot
//   * `DecisionLogged` category `system_event`, summary "System: stop" with
//     `details.origin` (rollback, disk-watchdog, …)       -> the system
//   * the cancel-notice family with NONE of the above     -> a safety abort
//
// The producer sets below are the REAL ones, mirrored from the D-suite
// (`skotiq_app/test/.../recent_events_feed_conformance_test.dart`) onto the
// core-typed event stream the router listens to.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

final _t0 = DateTime(2026, 8, 14, 2, 41);
const _runId = 15;

class _RecordingTransport extends NotificationTransport {
  @override
  final NotificationTransportKind kind = NotificationTransportKind.inApp;

  final List<({String title, String body})> sent = [];

  @override
  String get name => 'Recording in-app';

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    sent.add((title: title, body: body));
    return NotificationResult.ok();
  }
}

SkotiqEvent _sequencer(
  String eventType, {
  Map<String, dynamic> data = const {},
  EventSeverity severity = EventSeverity.info,
}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: severity,
  category: EventCategory.sequencer,
  eventType: eventType,
  data: data,
);

SkotiqEvent get _cancelNotice => _sequencer(
  'Error',
  data: const {'message': kSequenceCancelledNotice},
  severity: EventSeverity.error,
);

SkotiqEvent get _cancelDecision => _sequencer(
  'DecisionLogged',
  data: const {
    'category': 'system_event',
    'summary': kSequenceCancelledNotice,
    'details_json': '{"phase":"cancelled"}',
    'sequence_run_id': _runId,
  },
);

SkotiqEvent get _operatorDecision => _sequencer(
  'DecisionLogged',
  data: const {
    'category': 'manual_intervention',
    'summary': 'Operator: stop',
    'details_json': '{"action":"stop"}',
    'sequence_run_id': _runId,
  },
);

SkotiqEvent _autopilotDecision({int runId = _runId}) => _sequencer(
  'DecisionLogged',
  data: {
    'category': 'system_event',
    'summary': 'Autopilot: stop',
    'details_json': '{"origin":"scheduler","action":"stop"}',
    'sequence_run_id': runId,
  },
);

SkotiqEvent _systemDecision(String origin) => _sequencer(
  'DecisionLogged',
  data: {
    'category': 'system_event',
    'summary': 'System: stop',
    'details_json': '{"origin":"$origin","action":"stop"}',
    'sequence_run_id': _runId,
  },
);

SkotiqEvent _stopped({int? runId = _runId}) => _sequencer(
  'Stopped',
  data: runId == null ? const {} : {'sequence_run_id': runId},
);

/// One rig: a router whose systemPush transport feeds a real broadcaster, plus
/// an in-app recorder, driven by a clock that follows the fake elapsed time so
/// the episode window and the dedupe window are as deterministic as the timers.
/// A function, not a class, so the clock can close over [async].
({
  NotificationRouter router,
  PushNotificationService push,
  List<PushNotification> pushes,
  _RecordingTransport inApp,
})
_build(FakeAsync async) {
  final push = PushNotificationService();
  final inApp = _RecordingTransport();
  final router = NotificationRouter(
    transports: [inApp, SystemPushTransport(push)],
    matrix: NotificationRoutingMatrix.defaults(),
    clock: () => _t0.add(async.elapsed),
  );
  final pushes = <PushNotification>[];
  push.notifications.listen(pushes.add);
  return (router: router, push: push, pushes: pushes, inApp: inApp);
}

void main() {
  /// Drive [events] through a freshly built rig, let every timer and microtask
  /// settle, and hand the recorded output to [expectations].
  void drive(
    List<SkotiqEvent> Function() events,
    void Function(
      List<PushNotification> pushes,
      List<({String title, String body})> inApp,
    )
    expectations, {
    Duration settle = const Duration(seconds: 30),
  }) {
    fakeAsync((async) {
      final rig = _build(async);
      for (final event in events()) {
        rig.router.attachEventStream(Stream.value(event));
        async.elapse(const Duration(milliseconds: 1));
      }
      async.elapse(settle);
      expectations(rig.pushes, rig.inApp.sent);
      rig.router.dispose();
      rig.push.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  }

  test('the operator\'s own press never reaches the phone', () {
    drive(
      () => [
        _cancelNotice,
        _cancelDecision,
        _operatorDecision,
        _stopped(),
        _stopped(),
      ],
      (pushes, inApp) {
        expect(
          pushes,
          isEmpty,
          reason:
              'the operator is at the keyboard that issued the stop; '
              'got ${pushes.map((p) => p.body).toList()}',
        );
        expect(
          inApp,
          hasLength(1),
          reason: 'the in-app surface still says the run ended',
        );
      },
    );
  });

  test(
    'the manual-intervention decision arriving LAST still silences the push',
    () {
      // The stop API sends the executor command before recording the decision,
      // and that send yields — so the cancellation notice can win the race. The
      // push must wait long enough to hear who acted before it claims anything.
      drive(
        () => [_cancelNotice, _stopped(), _cancelDecision, _operatorDecision],
        (pushes, _) => expect(
          pushes,
          isEmpty,
          reason: 'got ${pushes.map((p) => p.body).toList()}',
        ),
      );
    },
  );

  test('an autopilot stop pushes once, naming the autopilot', () {
    drive(
      () => [
        _autopilotDecision(),
        _cancelNotice,
        _cancelDecision,
        _stopped(),
        _stopped(),
      ],
      (pushes, _) {
        expect(pushes, hasLength(1));
        expect(pushes.single.title, 'Sequence stopped');
        expect(pushes.single.body, contains('by autopilot'));
        expect(pushes.single.body, isNot(contains('by request')));
        expect(
          pushes.single.priority,
          isNot(PushNotificationPriority.critical),
          reason: 'INFO priority: a stop is never an alarm',
        );
      },
    );
  });

  test('a rollback stop names the rollback, not a human', () {
    drive(
      () => [
        _systemDecision('rollback'),
        _cancelNotice,
        _cancelDecision,
        _stopped(),
      ],
      (pushes, _) {
        expect(pushes, hasLength(1));
        expect(pushes.single.body, contains('rollback'));
        expect(pushes.single.body, isNot(contains('by request')));
        expect(pushes.single.body, isNot(contains('by autopilot')));
      },
    );
  });

  test('the headless disk watchdog\'s stop names the watchdog', () {
    drive(() => [_systemDecision('disk-watchdog'), _cancelNotice, _stopped()], (
      pushes,
      _,
    ) {
      expect(pushes, hasLength(1));
      expect(pushes.single.body, contains('disk'));
    });
  });

  test('a safety abort pushes once, cause-neutral', () {
    // The REAL abort producer set: every cancellation path publishes the
    // cancel-notice pair and the Stopped pair, and NOTHING names an author,
    // because nobody acted.
    drive(() => [_cancelNotice, _cancelDecision, _stopped(), _stopped()], (
      pushes,
      _,
    ) {
      expect(pushes, hasLength(1));
      expect(pushes.single.title, 'Sequence stopped');
      expect(pushes.single.body, isNot(contains('by request')));
      expect(pushes.single.body, isNot(contains('by autopilot')));
    });
  });

  test(
    'one stop episode is ONE push even when the terminal trails by 20 s',
    () {
      fakeAsync((async) {
        final rig = _build(async);
        for (final event in [_autopilotDecision(), _cancelNotice, _stopped()]) {
          rig.router.attachEventStream(Stream.value(event));
          async.elapse(const Duration(milliseconds: 1));
        }
        async.elapse(const Duration(seconds: 20));
        // The api publishes its own Stopped only after the whole safing
        // teardown; it belongs to the same episode and must not page again.
        rig.router.attachEventStream(Stream.value(_stopped()));
        async.elapse(const Duration(seconds: 30));

        expect(
          rig.pushes,
          hasLength(1),
          reason:
              'one stop, one push; got '
              '${rig.pushes.map((p) => p.body).toList()}',
        );
        rig.router.dispose();
        rig.push.dispose();
        async.elapse(const Duration(seconds: 1));
      });
    },
  );

  test('an operator press does not silence the NEXT run\'s autopilot stop', () {
    fakeAsync((async) {
      final rig = _build(async);
      void send(SkotiqEvent event) {
        rig.router.attachEventStream(Stream.value(event));
        async.elapse(const Duration(milliseconds: 1));
      }

      send(_cancelNotice);
      send(_operatorDecision);
      send(_stopped());
      async.elapse(const Duration(seconds: 30));
      expect(rig.pushes, isEmpty);

      // A new run starts and the autopilot ends it a few seconds later.
      send(_sequencer('Started'));
      send(_autopilotDecision(runId: 16));
      send(_cancelNotice);
      send(_stopped(runId: 16));
      async.elapse(const Duration(seconds: 30));

      expect(rig.pushes, hasLength(1));
      expect(rig.pushes.single.body, contains('by autopilot'));
      rig.router.dispose();
      rig.push.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  });

  test('the stop push is never critical priority', () {
    drive(() => [_cancelNotice, _stopped()], (pushes, _) {
      expect(pushes, hasLength(1));
      expect(pushes.single.priority, isNot(PushNotificationPriority.critical));
      expect(pushes.single.priority, isNot(PushNotificationPriority.high));
    });
  });

  // Decisions-verify refutation D2 (2026-08-14): the terminal `Stopped` trails
  // the press by however long the safing teardown takes — exposure abort, park,
  // dome close can exceed the 2-minute episode window. A matching run id is
  // proof of identity, and identity outranks time.
  test('a Stopped that trails the press beyond the episode window joins on '
      'run id and stays silent', () {
    fakeAsync((async) {
      final rig = _build(async);
      void send(SkotiqEvent event) {
        rig.router.attachEventStream(Stream.value(event));
        async.elapse(const Duration(milliseconds: 1));
      }

      send(_operatorDecision);
      send(_cancelNotice);
      async.elapse(const Duration(minutes: 3)); // the slow safing teardown
      send(_stopped()); // same _runId, three minutes late
      async.elapse(const Duration(seconds: 30));

      expect(
        rig.pushes,
        isEmpty,
        reason:
            'the operator pressed this stop; a slow teardown must not '
            'convert their own press into a cause-neutral push',
      );
      rig.router.dispose();
      rig.push.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  });

  // The control for the case above: with NO run id on either side, time is all
  // there is, so a late Stopped still opens its own episode and pushes.
  // Identity-joining must not widen into time-blindness.
  test('an id-less Stopped past the window still pushes (time is the only '
      'evidence left)', () {
    fakeAsync((async) {
      final rig = _build(async);
      void send(SkotiqEvent event) {
        rig.router.attachEventStream(Stream.value(event));
        async.elapse(const Duration(milliseconds: 1));
      }

      send(
        _sequencer(
          'DecisionLogged',
          data: const {
            'category': 'manual_intervention',
            'summary': 'Operator: stop',
            'details_json': '{"action":"stop"}',
          },
        ),
      );
      async.elapse(const Duration(minutes: 3));
      send(_stopped(runId: null));
      async.elapse(const Duration(seconds: 30));

      expect(rig.pushes, hasLength(1));
      rig.router.dispose();
      rig.push.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  });

  // Decisions-verify refutation D10 (2026-08-14): the autofocusContinued
  // category existed with honest copy but could not reach a phone — absent
  // from the default push matrix AND parked in the transport's never-escalate
  // arm. The exact row the executor writes must push, at the ordinary tier.
  test('the autofocus continuation reaches the phone at normal priority', () {
    drive(
      () => [
        _sequencer(
          'DecisionLogged',
          data: const {
            'category': 'system_event',
            'summary': 'Autofocus failed — continuing with last-good focus',
            'details_json': '{"trigger":"interval"}',
            'sequence_run_id': _runId,
          },
        ),
      ],
      (pushes, inApp) {
        expect(pushes, hasLength(1));
        expect(pushes.single.priority, PushNotificationPriority.normal);
        expect(inApp.map((m) => m.title), anyElement(contains('Autofocus')));
      },
    );
  });
}
