import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_progress.dart'
    show runEventStopEvidence;

/// Every way a run's end reaches the end-of-night decision, and what the
/// decision is. The table was written from the decisions the app made before
/// the run's end carried the native night-end cause, so a change to how the
/// cause travels must leave every row as it is.

/// A source of the run's stop as the wire delivers it.
class _Source {
  const _Source(this.label, {this.evidence, this.lastRunEndOrigin});

  final String label;
  final SequenceStopDecision? evidence;

  /// What the executor recorded as the run's end when no stop row named
  /// anybody.
  final String? lastRunEndOrigin;
}

SequenceStopDecision? _triggerRow(String id, String name) =>
    sequenceStopDecisionOf(
      SequencerStop.trigger(triggerId: id, triggerName: name),
    );

SequenceStopDecision? _triggerFired(
  String id,
  String name,
  SequencerTriggerAction action,
) => runEventStopEvidence(
  SequencerEvent.triggerFired(triggerId: id, triggerName: name, action: action),
);

final _sources = <_Source>[
  for (final (id, name) in const [
    ('dawn_approaching', 'Dawn Approaching'),
    ('obstruction', 'Obstruction'),
    ('weather_unsafe', 'Weather Unsafe'),
    ('altitude_limit', 'Altitude Limit'),
    ('guide_star_lost', 'Guide Star Lost'),
    ('recovery_node:n1', 'Recovery'),
    ('', 'Dawn Approaching'),
  ]) ...[
    _Source('row $id/$name', evidence: _triggerRow(id, name)),
    _Source(
      'fired $id/$name',
      evidence: _triggerFired(id, name, SequencerTriggerAction.parkAndAbort),
    ),
  ],
  _Source(
    'fired pause dawn_approaching',
    evidence: _triggerFired(
      'dawn_approaching',
      'Dawn Approaching',
      SequencerTriggerAction.pause,
    ),
  ),
  for (final origin in const [
    'rollback',
    'disk-watchdog',
    'end-of-night calibration',
    'dawn_approaching',
  ])
    _Source(
      'system $origin',
      evidence: sequenceStopDecisionOf(SequencerStop.system(origin: origin)),
    ),
  _Source(
    'operator',
    evidence: sequenceStopDecisionOf(const SequencerStop.operator_()),
  ),
  _Source(
    'autopilot',
    evidence: sequenceStopDecisionOf(const SequencerStop.autopilot()),
  ),
  for (final origin in const [
    null,
    'safety',
    'operator',
    'rollback',
    'scheduler',
  ])
    _Source('no row, last end $origin', lastRunEndOrigin: origin),
];

/// The coordinator's reading of a stop source as the run's origin.
String? _originOf(_Source source, SequenceRunStatus status) =>
    switch (source.evidence?.author) {
      SequenceStopAuthor.operatorPress => 'operator',
      SequenceStopAuthor.autopilot => 'autopilot',
      SequenceStopAuthor.system => source.evidence?.origin,
      null =>
        status == SequenceRunStatus.completed ? null : source.lastRunEndOrigin,
    };

String _decide(
  _Source source,
  SequenceRunStatus status, {
  required bool nightEnding,
  required bool parked,
}) {
  final reason = classifyRunEnd(
    runStatus: status,
    stopOrigin: _originOf(source, status),
    nightEnding: nightEnding,
    parked: parked,
  );
  return reason?.name ?? '-';
}

/// One line per source: the decision for every run status, as
/// `status:<night not ending><night ending><night ending, parked>`.
String _row(_Source source) {
  final cells = <String>[];
  for (final status in SequenceRunStatus.values) {
    final a = _decide(source, status, nightEnding: false, parked: false);
    final b = _decide(source, status, nightEnding: true, parked: false);
    final c = _decide(source, status, nightEnding: true, parked: true);
    cells.add('${status.name}:$a/$b/$c');
  }
  return '${source.label} | ${cells.join(' ')}';
}

const _today = <String>[
  'row dawn_approaching/Dawn Approaching | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/dawn aborted:dawn/dawn/dawn stopped:dawn/dawn/dawn stoppedResumable:dawn/dawn/dawn interrupted:-/-/-',
  'fired dawn_approaching/Dawn Approaching | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/dawn aborted:dawn/dawn/dawn stopped:dawn/dawn/dawn stoppedResumable:dawn/dawn/dawn interrupted:-/-/-',
  'row obstruction/Obstruction | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/obstruction aborted:obstruction/obstruction/obstruction stopped:obstruction/obstruction/obstruction stoppedResumable:obstruction/obstruction/obstruction interrupted:-/-/-',
  'fired obstruction/Obstruction | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/obstruction aborted:obstruction/obstruction/obstruction stopped:obstruction/obstruction/obstruction stoppedResumable:obstruction/obstruction/obstruction interrupted:-/-/-',
  'row weather_unsafe/Weather Unsafe | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/dawn/dawn stopped:-/dawn/dawn stoppedResumable:-/dawn/dawn interrupted:-/-/-',
  'fired weather_unsafe/Weather Unsafe | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/dawn/dawn stopped:-/dawn/dawn stoppedResumable:-/dawn/dawn interrupted:-/-/-',
  'row altitude_limit/Altitude Limit | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'fired altitude_limit/Altitude Limit | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'row guide_star_lost/Guide Star Lost | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'fired guide_star_lost/Guide Star Lost | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'row recovery_node:n1/Recovery | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'fired recovery_node:n1/Recovery | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'row /Dawn Approaching | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'fired /Dawn Approaching | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'fired pause dawn_approaching | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/dawn/dawn stopped:-/dawn/dawn stoppedResumable:-/dawn/dawn interrupted:-/-/-',
  'system rollback | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'system disk-watchdog | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'system end-of-night calibration | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'system dawn_approaching | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/dawn aborted:dawn/dawn/dawn stopped:dawn/dawn/dawn stoppedResumable:dawn/dawn/dawn interrupted:-/-/-',
  'operator | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'autopilot | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'no row, last end null | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/dawn/dawn stopped:-/dawn/dawn stoppedResumable:-/dawn/dawn interrupted:-/-/-',
  'no row, last end safety | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/dawn/dawn stopped:-/dawn/dawn stoppedResumable:-/dawn/dawn interrupted:-/-/-',
  'no row, last end operator | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'no row, last end rollback | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
  'no row, last end scheduler | running:-/-/- paused:-/-/- completed:targetsComplete/targetsComplete/targetsComplete failed:-/-/- aborted:-/-/- stopped:-/-/- stoppedResumable:-/-/- interrupted:-/-/-',
];

void main() {
  test('every stop source ends the night as it did', () {
    expect(_sources.map(_row).toList(), _today);
  });
}
