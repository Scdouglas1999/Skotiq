// RECENT EVENTS conformance: the stop-family fold + the time-windowed
// collapse. Adopted from the Wave-H refuter, made honest by the Wave-I
// refuter (I7): the press harness now emits the REAL producer set including
// the manual-intervention decision (the only once-per-run-stop event that
// proves an operator acted — sequencer/src/executor/lifecycle.rs), the abort
// harness emits the REAL cancellation set (every cancel path publishes the
// cancel-notice pair, weather/dome ParkAndAbort included), and the window
// case pins a title the collapse may actually fold.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as be;
import 'package:skotiq_core/skotiq_core.dart';

final _t0 = DateTime(2026, 8, 13, 1, 54, 26);

be.SkotiqEvent _error(int id, String message, DateTime at) =>
    be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: be.EventSeverity.error,
      category: be.EventCategory.sequencer,
      payload: be.EventPayload.sequencer(
        be.SequencerEvent.error(message: message),
      ),
    );

be.SkotiqEvent _decision(int id, String summary, DateTime at) =>
    be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: be.EventSeverity.info,
      category: be.EventCategory.sequencer,
      payload: be.EventPayload.sequencer(
        be.SequencerEvent.decisionLogged(
          timestampIso: at.toUtc().toIso8601String(),
          category: 'system_event',
          summary: summary,
          detailsJson: '{"phase":"cancelled"}',
          sequenceRunId: 15,
        ),
      ),
    );

be.SkotiqEvent _manualStop(int id, DateTime at) => be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: be.EventSeverity.info,
      category: be.EventCategory.sequencer,
      payload: be.EventPayload.sequencer(
        be.SequencerEvent.decisionLogged(
          timestampIso: at.toUtc().toIso8601String(),
          category: 'manual_intervention',
          summary: 'Operator: stop requested',
          detailsJson: '{}',
          sequenceRunId: 15,
        ),
      ),
    );

be.SkotiqEvent _stopped(int id, DateTime at, {int? runId}) =>
    be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: be.EventSeverity.info,
      category: be.EventCategory.sequencer,
      payload: be.EventPayload.sequencer(
        be.SequencerEvent.stopped(sequenceRunId: runId),
      ),
    );

be.SkotiqEvent _autopilotStop(int id, DateTime at, {int? runId}) =>
    be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: be.EventSeverity.info,
      category: be.EventCategory.sequencer,
      payload: be.EventPayload.sequencer(
        be.SequencerEvent.decisionLogged(
          timestampIso: at.toUtc().toIso8601String(),
          category: 'system_event',
          summary: 'Autopilot: stop',
          detailsJson: '{"origin":"scheduler","action":"stop"}',
          sequenceRunId: runId ?? 15,
        ),
      ),
    );

be.SkotiqEvent _started(int id, DateTime at) => be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: at.millisecondsSinceEpoch,
      severity: be.EventSeverity.info,
      category: be.EventCategory.sequencer,
      payload: be.EventPayload.sequencer(
        be.SequencerEvent.started(sequenceName: 'Tonight'),
      ),
    );

RunDashboardEvent _row(String title, String message, DateTime at) =>
    RunDashboardEvent(
      eventId: BigInt.from(at.millisecondsSinceEpoch),
      time: at,
      severity: RunDashboardEventSeverity.warning,
      category: 'Guiding',
      title: title,
      message: message,
      isCritical: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// The REAL operator-press producer set: the cancel-notice pair, the
  /// manual-intervention decision from SequencerExecutor::stop, and the
  /// terminal Stopped pair.
  void pressStop(ProviderContainer c, {required int base, DateTime? at}) {
    final when = at ?? _t0;
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(base, kSequenceCancelledNotice, when));
    h.addEvent(_decision(base + 1, kSequenceCancelledNotice, when));
    h.addEvent(_manualStop(base + 2, when));
    h.addEvent(_stopped(base + 3, when));
    h.addEvent(_stopped(base + 4, when));
  }

  /// The REAL safety-abort producer set: every cancellation path (weather,
  /// dome, ParkAndAbort) runs the same is_cancelled machinery and publishes
  /// the cancel-notice Error AND decision plus the Stopped pair — but NO
  /// manual-intervention decision, because no operator acted.
  void abortStop(ProviderContainer c, {required int base, DateTime? at}) {
    final when = at ?? _t0;
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(base, kSequenceCancelledNotice, when));
    h.addEvent(_decision(base + 1, kSequenceCancelledNotice, when));
    h.addEvent(_stopped(base + 2, when));
    h.addEvent(_stopped(base + 3, when));
  }

  // ---------------------------------------------------------------- (c) window

  test('C1 a genuine repeat storm spaced 60 s apart stays ONE row', () {
    // A flapping condition that re-reports every minute for 25 minutes. Every
    // neighbouring pair is 60 s apart, so by the stated rule ("identical rows
    // further apart than 10 minutes are separate happenings") this is one
    // happening, still going.
    final rows = <RunDashboardEvent>[
      for (var i = 0; i < 26; i++)
        _row(
          'Guider disconnected',
          'Guider · reconnecting',
          _t0.subtract(Duration(minutes: i)),
        ),
    ];
    final out = collapseRepeatedEvents(rows);
    expect(
      out,
      hasLength(1),
      reason: 'got ${out.length} rows: '
          '${out.map((e) => '${e.time.toIso8601String()} x${e.repeatCount}').toList()}',
    );
  });

  test('C2 two identical rows 20 minutes apart stay two rows', () {
    // Uses a collapsible title on purpose: stop rows are categorically
    // exempt from the collapse, so they cannot pin the 10-minute window.
    final out = collapseRepeatedEvents([
      _row('Guider disconnected', 'Guider · reconnecting', _t0),
      _row(
        'Guider disconnected',
        'Guider · reconnecting',
        _t0.subtract(const Duration(minutes: 20)),
      ),
    ]);
    expect(out, hasLength(2));
  });

  test('C3 two stops of two different runs, 5 minutes apart', () {
    final c = makeContainer();
    final firstStop = _t0.subtract(const Duration(minutes: 5));
    pressStop(c, base: 1, at: firstStop);
    // run 2 starts and is stopped five minutes later
    c
        .read(eventHistoryProvider.notifier)
        .addEvent(_started(20, firstStop.add(const Duration(minutes: 1))));
    pressStop(c, base: 30, at: _t0);

    final recent = c.read(runDashboardRecentEventsProvider(10));
    expect(
      recent.where((e) => e.title == 'Sequence stopped').length,
      2,
      reason: 'two operator decisions five minutes apart. Got: '
          '${recent.map((e) => '${e.title}/${e.message}/x${e.repeatCount}').toList()}',
    );
  });

  test('C4 the same two stops with NO event between them', () {
    final c = makeContainer();
    pressStop(c, base: 1, at: _t0.subtract(const Duration(minutes: 5)));
    pressStop(c, base: 30, at: _t0);

    final recent = c.read(runDashboardRecentEventsProvider(10));
    expect(
      recent.map((e) => '${e.title} x${e.repeatCount}').toList(),
      ['Sequence stopped x1', 'Sequence stopped x1'],
      reason: 'two stops five minutes apart with nothing between them',
    );
  });

  // ------------------------------------------------------------- (d) stop fold

  test('D1 one press of Stop is one row (baseline)', () {
    final c = makeContainer();
    pressStop(c, base: 1);
    final recent = c.read(runDashboardRecentEventsProvider(5));
    expect(recent, hasLength(1));
    expect(recent.single.title, 'Sequence stopped');
    expect(recent.single.message, kSequenceStoppedByRequestMessage);
    expect(recent.single.repeatCount, 1);
  });

  test('D2 a real error 3 s AFTER the stop survives', () {
    final c = makeContainer();
    pressStop(c, base: 1);
    c.read(eventHistoryProvider.notifier).addEvent(
          _error(
            50,
            'Failed to park mount: limit switch',
            _t0.add(const Duration(seconds: 3)),
          ),
        );
    final recent = c.read(runDashboardRecentEventsProvider(5));
    expect(
      recent.any((e) => e.message.contains('limit switch')),
      isTrue,
      reason: 'rows: ${recent.map((e) => '${e.title}/${e.message}').toList()}',
    );
    expect(recent.where((e) => e.title == 'Sequence stopped'), hasLength(1));
  });

  test('D3 a real error 3 s BEFORE the stop survives', () {
    final c = makeContainer();
    c.read(eventHistoryProvider.notifier).addEvent(
          _error(
            50,
            'Guide star lost past the limit',
            _t0.subtract(const Duration(seconds: 3)),
          ),
        );
    pressStop(c, base: 1);
    final recent = c.read(runDashboardRecentEventsProvider(5));
    expect(recent.any((e) => e.message.contains('Guide star lost')), isTrue);
    expect(recent.where((e) => e.title == 'Sequence stopped'), hasLength(1));
  });

  test('D4 a real error INSIDE the stop family (interleaved) — one stop row?',
      () {
    // Producers 3 and 4 are separated by the whole safing/park teardown, so a
    // device/park event landing between them is the normal live case.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_stopped(3, _t0));
    h.addEvent(
      _error(
        4,
        'Dome shutter failed to close',
        _t0.add(const Duration(seconds: 2)),
      ),
    );
    h.addEvent(_stopped(5, _t0.add(const Duration(seconds: 4))));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    expect(
      recent.any((e) => e.message.contains('Dome shutter')),
      isTrue,
      reason: 'the real error must never be eaten',
    );
    expect(
      recent.where((e) => e.title == 'Sequence stopped'),
      hasLength(1),
      reason: 'one press of Stop. Got: '
          '${recent.map((e) => '${e.title}/${e.message}').toList()}',
    );
  });

  test('D5 a REAL safety abort must not read as "Stopped by request"', () {
    // A weather/dome ParkAndAbort cancels through the
    // same machinery as an operator stop and therefore publishes the SAME
    // cancel-notice Error and decision — but no manual-intervention
    // decision, because nobody was at the keyboard. The stop row must stay
    // cause-neutral and the weather error must survive as its own row.
    final c = makeContainer();
    c.read(eventHistoryProvider.notifier).addEvent(
          _error(50, 'Weather unsafe: cloud sensor tripped', _t0),
        );
    abortStop(c, base: 1, at: _t0.add(const Duration(seconds: 1)));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(stopRows, hasLength(1));
    expect(
      stopRows.single.message,
      isNot(kSequenceStoppedByRequestMessage),
      reason: 'no operator acted; rows: '
          '${recent.map((e) => '${e.severity.name} ${e.title}/${e.message}').toList()}',
    );
    expect(recent.any((e) => e.message.contains('cloud sensor')), isTrue);
  });

  test('D6 a genuine repeat storm of stops is not silently thinned', () {
    // Four presses of Stop, one every 3 s (an operator mashing Stop while the
    // run refuses to end). Each press is a real event the log must show.
    final c = makeContainer();
    for (var i = 0; i < 4; i++) {
      pressStop(
        c,
        base: 1 + i * 10,
        at: _t0.add(Duration(seconds: 3 * i)),
      );
    }
    final recent = c.read(runDashboardRecentEventsProvider(10));
    expect(
      recent.where((e) => e.title == 'Sequence stopped').length,
      4,
      reason: 'four presses in 9 s must be four rows, got '
          '${recent.map((e) => '${e.title} x${e.repeatCount}').toList()}',
    );
  });

  test('D7 the api Stopped can trail the press by 20 s and still folds in', () {
    // api_sequencer_stop publishes its Stopped only
    // after the whole safing teardown, which can take arbitrarily long. One
    // press stays ONE row, the emitted (newest) row keeps its OWN time and
    // eventId, and it carries the cause.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_manualStop(3, _t0));
    h.addEvent(_stopped(4, _t0));
    h.addEvent(_stopped(5, _t0.add(const Duration(seconds: 20))));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(
      stopRows,
      hasLength(1),
      reason: 'one press. Got: '
          '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}/${e.message}').toList()}',
    );
    expect(stopRows.single.message, kSequenceStoppedByRequestMessage,
        reason: 'the visible row must carry the cause, not sit empty');
    for (var i = 0; i + 1 < recent.length; i++) {
      expect(recent[i].time.isBefore(recent[i + 1].time), isFalse,
          reason: 'the feed stays newest-first');
    }
  });

  test('D8 the fold never breaks the feed newest-first ordering', () {
    // Learning the cause must copy the MESSAGE into
    // the emitted row, never swap in an older member's row wholesale.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_manualStop(3, _t0));
    h.addEvent(_stopped(4, _t0));
    h.addEvent(
      _error(
        5,
        'Dome shutter failed to close',
        _t0.add(const Duration(seconds: 4)),
      ),
    );
    h.addEvent(_stopped(6, _t0.add(const Duration(seconds: 6))));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    for (var i = 0; i + 1 < recent.length; i++) {
      expect(
        recent[i].time.isBefore(recent[i + 1].time),
        isFalse,
        reason: 'row $i is older than row ${i + 1}: '
            '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}').toList()}',
      );
    }
    expect(recent.any((e) => e.message.contains('Dome shutter')), isTrue);
  });

  test('D9 an earlier run\'s bare Stopped survives a stop 4 s later', () {
    // Run 1 ends with only its terminal Stopped, the
    // operator restarts, and stops run 2 four seconds later. The Started
    // between them is the run boundary — the two stops must not merge.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, 'Mount tracking lost', _t0));
    h.addEvent(_stopped(2, _t0));
    h.addEvent(_started(3, _t0.add(const Duration(seconds: 1))));
    pressStop(c, base: 10, at: _t0.add(const Duration(seconds: 4)));

    final recent = c.read(runDashboardRecentEventsProvider(10));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(
      stopRows,
      hasLength(2),
      reason: 'two runs ended. Got: '
          '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}/${e.message}').toList()}',
    );
    // Run 1's row is cause-neutral; run 2's carries the operator cause.
    expect(stopRows.last.message, isEmpty);
    expect(stopRows.first.message, kSequenceStoppedByRequestMessage);
  });

  test('D10 a stop 40 minutes earlier is never absorbed, boundary or not', () {
    // The Started boundary is published by exactly one producer; where it is
    // missing (attached session, truncated stream) the fold must degrade to TWO
    // rows, never delete the earlier one. A bare terminal Stopped 40 minutes
    // before a press shares no episode with it.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_stopped(1, _t0.subtract(const Duration(minutes: 40))));
    pressStop(c, base: 10, at: _t0);

    final recent = c.read(runDashboardRecentEventsProvider(10));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(
      stopRows,
      hasLength(2),
      reason: 'two happenings 40 minutes apart. Got: '
          '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}/${e.message}').toList()}',
    );
    expect(stopRows.last.message, isEmpty,
        reason: 'the old bare Stopped proves no operator action');
  });

  test('D11 with the operator decision absent a press degrades NEUTRAL', () {
    // The floor: if the manual-intervention decision is missing (older
    // builds), the press's remaining producers are byte-identical to a safety
    // abort and the row must stay cause-neutral — the safe direction, never the
    // invented one.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_stopped(2, _t0));
    h.addEvent(_stopped(3, _t0));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(stopRows, hasLength(1));
    expect(stopRows.single.message, isNot(kSequenceStoppedByRequestMessage));
  });

  test('D12 a kind-poor natural terminal keeps its own row beside a press', () {
    // A run cancelled by executor state alone publishes a bare Stopped and
    // nothing else. Four seconds later the operator stops the NEXT run (its
    // Started between). Both rows survive.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_stopped(1, _t0));
    h.addEvent(_started(2, _t0.add(const Duration(seconds: 1))));
    pressStop(c, base: 10, at: _t0.add(const Duration(seconds: 4)));

    final recent = c.read(runDashboardRecentEventsProvider(10));
    expect(
      recent.where((e) => e.title == 'Sequence stopped'),
      hasLength(2),
    );
  });

  test('D13 a 14s teardown with a mid-family error stays one press row', () {
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_manualStop(3, _t0));
    h.addEvent(_stopped(4, _t0));
    h.addEvent(
      _error(
        5,
        'Dome shutter failed to close',
        _t0.add(const Duration(seconds: 2)),
      ),
    );
    h.addEvent(_stopped(6, _t0.add(const Duration(seconds: 14))));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    expect(
      recent.where((e) => e.title == 'Sequence stopped'),
      hasLength(1),
      reason: 'one press with a 14s teardown. Got: '
          '${recent.map((e) => '${e.title}/${e.message}').toList()}',
    );
    expect(recent.any((e) => e.message.contains('Dome shutter')), isTrue);
  });

  test('D14 run identity outranks time: different runs 90 s apart never merge',
      () {
    // Merge direction: a bare terminal of run 1 and a
    // press of run 2 ninety seconds later, with NO Started between (attached
    // session / truncated stream). The run ids on the wire keep them apart.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_stopped(1, _t0, runId: 14));
    final press = _t0.add(const Duration(seconds: 90));
    h.addEvent(_error(10, kSequenceCancelledNotice, press));
    h.addEvent(_decision(11, kSequenceCancelledNotice, press));
    h.addEvent(_manualStop(12, press));
    h.addEvent(_stopped(13, press, runId: 15));

    final recent = c.read(runDashboardRecentEventsProvider(10));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(
      stopRows,
      hasLength(2),
      reason: 'two runs ended. Got: '
          '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}/${e.message}').toList()}',
    );
    expect(stopRows.last.message, isEmpty,
        reason: "run 14's ending must not be re-attributed to the operator");
  });

  test('D15 run identity outranks the bound: a 5-minute teardown folds in', () {
    // Split direction: the api Stopped can trail the
    // press by the WHOLE safing teardown. With the run id on the wire the
    // late terminal joins its own episode however long that took.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_manualStop(3, _t0));
    h.addEvent(_stopped(4, _t0, runId: 15));
    h.addEvent(_stopped(5, _t0.add(const Duration(minutes: 5)), runId: 15));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(
      stopRows,
      hasLength(1),
      reason: 'one press, one row. Got: '
          '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}/${e.message}').toList()}',
    );
    expect(stopRows.single.message, kSequenceStoppedByRequestMessage);
  });

  test("D16 the autopilot's stop names the autopilot, never the operator", () {
    // The scheduler drives the same stop path on an
    // unattended re-plan. Its decision is system-origin evidence and the
    // row must say so — a 2 a.m. autopilot stop rendering "Stopped by
    // request" invents a human that was not there.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_autopilotStop(3, _t0));
    h.addEvent(_stopped(4, _t0, runId: 15));
    h.addEvent(_stopped(5, _t0, runId: 15));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(
      stopRows,
      hasLength(1),
      reason: 'one autopilot stop. Got: '
          '${recent.map((e) => '${e.title}/${e.message}').toList()}',
    );
    expect(stopRows.single.message, kSequenceStoppedByAutopilotMessage);
    expect(stopRows.single.message, isNot(kSequenceStoppedByRequestMessage));
  });

  test('D17 stepping-stone chaining cannot stretch the id-less bound', () {
    // Six id-less terminal Stopped events 110 s apart
    // (every adjacent pair inside the 2-minute bound, total span 9m10s).
    // Joins measure to the episode SPINE, not to fellow id-less members, so
    // the chain breaks and the night's record keeps multiple rows.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    for (var i = 0; i < 6; i++) {
      h.addEvent(_stopped(1 + i, _t0.add(Duration(seconds: 110 * i))));
    }
    final recent = c.read(runDashboardRecentEventsProvider(10));
    expect(
      recent.where((e) => e.title == 'Sequence stopped').length,
      3,
      reason: 'the fold is deterministic: groups open at t0, t+220s, t+440s, '
          'each absorbing its 110s neighbour. One row would mean unbounded '
          'absorption; more than three would mean adjacent members no '
          'longer fold at all. Got: '
          '${recent.map((e) => '${e.time.toIso8601String()} ${e.title}').toList()}',
    );
  });

  test('D18 a rollback stop stays cause-neutral', () {
    // A failed-launch rollback issues a real native
    // stop with origin `rollback`; the executor records a SystemEvent, not
    // operator evidence, so the feed's stop row must stay neutral.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(_error(1, kSequenceCancelledNotice, _t0));
    h.addEvent(_decision(2, kSequenceCancelledNotice, _t0));
    h.addEvent(_stopped(3, _t0, runId: 15));

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final stopRows =
        recent.where((e) => e.title == 'Sequence stopped').toList();
    expect(stopRows, hasLength(1));
    expect(stopRows.single.message, isNot(kSequenceStoppedByRequestMessage));
    expect(stopRows.single.message, isNot(kSequenceStoppedByAutopilotMessage));
  });

  test('D19 one completed run shows ONE unbadged completion row', () {
    // The wire carries a completed run twice (explicit terminal + the
    // state-change echo). One row, repeatCount 1 — "x2" would claim two
    // completions that never happened.
    final c = makeContainer();
    final h = c.read(eventHistoryProvider.notifier);
    h.addEvent(
      be.SkotiqEvent(
        eventId: BigInt.from(1),
        timestamp: _t0.millisecondsSinceEpoch,
        severity: be.EventSeverity.info,
        category: be.EventCategory.sequencer,
        payload: const be.EventPayload.sequencer(be.SequencerEvent.completed()),
      ),
    );
    h.addEvent(
      be.SkotiqEvent(
        eventId: BigInt.from(2),
        timestamp: _t0.millisecondsSinceEpoch,
        severity: be.EventSeverity.info,
        category: be.EventCategory.sequencer,
        payload: const be.EventPayload.sequencer(be.SequencerEvent.completed()),
      ),
    );

    final recent = c.read(runDashboardRecentEventsProvider(5));
    final rows = recent.where((e) => e.title == 'Sequence complete').toList();
    expect(rows, hasLength(1));
    expect(rows.single.repeatCount, 1);
  });
}
