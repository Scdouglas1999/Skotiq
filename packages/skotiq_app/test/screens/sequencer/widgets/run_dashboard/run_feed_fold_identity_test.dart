// Which rows the trigger feed folds together, and why: a stop episode to one
// row, a doubled completion to one row, everything else by identical content.
// Pinned on the code that folded by the titles it wrote, so the fold by row
// kind can be checked against it.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/run_dashboard_providers.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as be;

final _t0 = DateTime(2026, 11, 22, 1, 0, 0);

be.SkotiqEvent _event(
  int id,
  Duration at,
  be.EventPayload payload, {
  be.EventCategory category = be.EventCategory.sequencer,
  be.EventSeverity severity = be.EventSeverity.info,
}) =>
    be.SkotiqEvent(
      eventId: BigInt.from(id),
      timestamp: _t0.add(at).millisecondsSinceEpoch,
      severity: severity,
      category: category,
      payload: payload,
    );

be.SkotiqEvent _stopped(int id, Duration at, {int? runId}) => _event(
      id,
      at,
      be.EventPayload.sequencer(
        be.SequencerEvent.stopped(
          sequenceRunId: runId,
        ),
      ),
    );

be.SkotiqEvent _completed(int id, Duration at) => _event(
      id,
      at,
      const be.EventPayload.sequencer(be.SequencerEvent.completed()),
    );

be.SkotiqEvent _started(int id, Duration at) => _event(
      id,
      at,
      const be.EventPayload.sequencer(
        be.SequencerEvent.started(sequenceName: 'M31'),
      ),
    );

be.SkotiqEvent _notification(int id, Duration at, String title) => _event(
      id,
      at,
      be.EventPayload.system(
        be.SystemEvent.notification(
          title: title,
          message: 'from the host',
          level: 'info',
        ),
      ),
      category: be.EventCategory.system,
    );

/// The feed, oldest event last as the stream holds them, as
/// `title|message|xN` lines.
List<String> _feed(List<be.SkotiqEvent> newestFirst) => [
      for (final row in runDashboardFeedRows(newestFirst))
        '${row.title}|${row.message}|x${row.repeatCount}',
    ];

void main() {
  const s = Duration(seconds: 1);

  test('two stops of one run read as one row', () {
    expect(
      _feed([_stopped(2, s * 3, runId: 7), _stopped(1, s, runId: 7)]),
      ['Sequence stopped||x1'],
    );
  });

  test('stops of two runs a run apart stay two rows without a badge', () {
    expect(
      _feed([
        _stopped(3, s * 1200, runId: 8),
        _started(2, s * 600),
        _stopped(1, s, runId: 7),
      ]),
      [
        'Sequence stopped||x1',
        'Sequence started|M31|x1',
        'Sequence stopped||x1',
      ],
    );
  });

  test('id-less stops more than two minutes apart never wear a badge', () {
    expect(
      _feed([_stopped(2, s * 200), _stopped(1, s)]),
      ['Sequence stopped||x1', 'Sequence stopped||x1'],
    );
  });

  test('a doubled completion reads as one row', () {
    expect(
      _feed([_completed(2, s * 4), _completed(1, s)]),
      ['Sequence complete||x1'],
    );
  });

  test('completions further apart than the echo stay two rows, no badge', () {
    expect(
      _feed([_completed(2, s * 30), _completed(1, s)]),
      ['Sequence complete||x1', 'Sequence complete||x1'],
    );
  });

  test('repeated other rows collapse with a count', () {
    expect(
      _feed([
        _notification(3, s * 3, 'Dew heater'),
        _notification(2, s * 2, 'Dew heater'),
        _notification(1, s, 'Dew heater'),
      ]),
      ['Dew heater|from the host (info)|x3'],
    );
  });

  group('a host notification that happens to carry a run title', () {
    test('titled Sequence stopped, it is a row of its own', () {
      expect(
        _feed([
          _notification(2, s * 3, 'Sequence stopped'),
          _stopped(1, s, runId: 7),
        ]),
        ['Sequence stopped|from the host (info)|x1', 'Sequence stopped||x1'],
      );
    });

    test('titled Sequence complete, it is a row of its own', () {
      expect(
        _feed([
          _notification(2, s * 3, 'Sequence complete'),
          _completed(1, s),
        ]),
        ['Sequence complete|from the host (info)|x1', 'Sequence complete||x1'],
      );
    });
  });
}
