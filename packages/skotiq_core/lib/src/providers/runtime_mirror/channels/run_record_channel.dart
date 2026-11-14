import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/backend/sequencer_status.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../models/sequence/sequence_run_status.dart';
import '../../sequence/last_ended_run.dart';
import '../../sequence/run_record.dart';
import '../../../models/sequence/run_stop_classification.dart';
import '../../sequence/sequence_progress.dart';
import '../../sequence/sequence_selection.dart';
import '../../sequence_stats_provider.dart';
import '../../../models/sequence/terminal_run_result.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

typedef RunRecordSnapshot = ({
  SequenceTerminalRunResult? terminal,
  CompletedImagingRun? imagingRun,
  LastEndedRun? lastEnded,
  bool lastEndedPlanLoaded,
  SequenceStopDecision? stopEvidence,
  DateTime? runStartedAt,
  SequenceRunStats? stats,
});

final _runRecordSnapshotProvider = Provider<RunRecordSnapshot>((ref) {
  final lastEnded = ref.watch(lastEndedRunProvider);
  return (
    terminal: ref.watch(sequenceTerminalRunResultProvider),
    imagingRun: ref.watch(completedImagingRunProvider),
    lastEnded: lastEnded,
    lastEndedPlanLoaded:
        lastEnded != null &&
        lastEnded.ranLoadedPlan(
          ref.watch(currentSequenceProvider.select((s) => s?.id)),
        ),
    stopEvidence: ref.watch(sequenceStopEvidenceProvider),
    runStartedAt: ref.watch(runStartedAtProvider),
    stats: ref.watch(liveSequenceStatsProvider),
  );
});

/// Wire name of [RunRecordChannel].
const String runRecordChannelKey = 'runRecord';

/// What the host remembers about the run: how it ended, which session holds
/// its frames, its counters as they stand, and when it started.
///
/// The host's Tonight keeps a finished night on screen from these, but each
/// app only learned them by watching the run end, so a client that connected
/// after the run (or restarted during it) showed "Ready · not started", an
/// empty frame strip and a plan with no frames while the host showed the
/// run's results.
class RunRecordChannel extends RuntimeMirrorChannel<RunRecordSnapshot> {
  const RunRecordChannel();

  @override
  String get key => runRecordChannelKey;

  @override
  get source => _runRecordSnapshotProvider;

  @override
  Map<String, dynamic>? encode(RunRecordSnapshot value) {
    final imagingRun = value.imagingRun;
    final lastEnded = value.lastEnded;
    return {
      'terminal': _encodeResult(value.terminal),
      'imagingRun': imagingRun == null
          ? null
          : {
              'result': _encodeResult(imagingRun.result),
              'stats': _encodeStats(imagingRun.stats),
            },
      'lastEnded': lastEnded == null
          ? null
          : {
              'sequenceId': lastEnded.sequenceId,
              'endedAt': lastEnded.endedAt.toUtc().millisecondsSinceEpoch,
              // The client cannot tell by the id: its id for the same plan
              // is its own.
              'planLoaded': value.lastEndedPlanLoaded,
            },
      // Who ended the run. A client learns it from the run's events only
      // while it is connected and listening; the host always knows.
      'stop': _encodeStop(value.stopEvidence),
      'runStartedAt': value.runStartedAt?.toUtc().millisecondsSinceEpoch,
      // The run's vitals as they stand: the session vitals tile.
      'stats': _encodeStats(value.stats),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || context.networkBackend == null) return;

    final terminal = _decodeResult(value['terminal']);
    final rawImagingRun = value['imagingRun'];
    CompletedImagingRun? imagingRun;
    if (rawImagingRun is Map) {
      final result = _decodeResult(rawImagingRun['result']);
      if (result != null) {
        imagingRun = CompletedImagingRun(
          result,
          _decodeStats(rawImagingRun['stats']),
        );
      }
    }
    final rawLastEnded = value['lastEnded'];
    LastEndedRun? lastEnded;
    if (rawLastEnded is Map) {
      final sequenceId = jsonString(rawLastEnded['sequenceId']);
      final endedAt = jsonInstant(rawLastEnded['endedAt']);
      if (sequenceId != null && endedAt != null) {
        final planLoaded = rawLastEnded['planLoaded'];
        lastEnded = LastEndedRun(
          sequenceId: sequenceId,
          endedAt: endedAt.toLocal(),
          planLoadedOnHost: planLoaded is bool ? planLoaded : null,
        );
      }
    }

    final run = context.read(runRecordProvider.notifier);
    run.mirrorHostRunRecord(
      terminal: terminal,
      completedImagingRun: imagingRun,
      lastEnded: lastEnded,
      startedAt: jsonInstant(value['runStartedAt'])?.toLocal(),
    );
    // A host from before this field says nothing; what the client gathered
    // from the events stands.
    if (value.containsKey('stop')) {
      run.setStopEvidence(_decodeStop(value['stop']));
    }
    run.setStats(_decodeStats(value['stats']));
  }
}

Map<String, dynamic>? _encodeStop(SequenceStopDecision? stop) => stop == null
    ? null
    : {
        'author': stop.author.name,
        'origin': stop.origin,
        'originLabel': stop.originLabel,
        'parked': stop.parked,
      };

SequenceStopDecision? _decodeStop(Object? raw) {
  if (raw is! Map) return null;
  final author = SequenceStopAuthor.values
      .where((a) => a.name == raw['author'])
      .firstOrNull;
  if (author == null) return null;
  return SequenceStopDecision(
    author,
    origin: jsonString(raw['origin']),
    originLabel: jsonString(raw['originLabel']),
    parked: raw['parked'] == true,
  );
}

Map<String, dynamic>? _encodeResult(SequenceTerminalRunResult? result) {
  if (result == null) return null;
  return {
    'generation': result.generation,
    'outcome': result.outcome.name,
    'runStatus': result.runStatus.token,
    'runId': result.runId,
    'dbSessionId': result.dbSessionId,
    'isCalibration': result.isCalibration,
  };
}

SequenceTerminalRunResult? _decodeResult(Object? raw) {
  if (raw is! Map) return null;
  final outcome = SequenceExecutionState.values
      .where((s) => s.name == raw['outcome'])
      .firstOrNull;
  final runStatus = SequenceRunStatus.tryParse(jsonString(raw['runStatus']));
  if (outcome == null || runStatus == null) {
    throw const FormatException('Run record has no outcome or run status');
  }
  return SequenceTerminalRunResult(
    generation: requireInt(raw, 'generation'),
    outcome: outcome,
    runStatus: runStatus,
    runId: jsonInt(raw['runId']),
    dbSessionId: jsonInt(raw['dbSessionId']),
    isCalibration: raw['isCalibration'] == true,
  );
}

Map<String, dynamic>? _encodeStats(SequenceRunStats? stats) {
  if (stats == null) return null;
  return SequencerRunVitals(
    startTime: stats.startTime,
    endTime: stats.endTime,
    framesCaptured: stats.framesCaptured,
    framesRejected: stats.framesRejected,
    integrationSecs: stats.integrationSecs,
    triggerFires: stats.triggerFires,
    autofocusRuns: stats.autofocusRuns,
    meridianFlips: stats.meridianFlips,
    ditherCount: stats.ditherCount,
    warningMessages: stats.warningMessages,
    errorMessages: stats.errorMessages,
    rejectFolder: stats.rejectFolder,
    terminalCause: stats.terminalCause,
  ).toJson();
}

SequenceRunStats? _decodeStats(Object? raw) {
  if (raw is! Map) return null;
  return SequenceRunStats.fromRemoteVitals(
    SequencerRunVitals.fromJson(Map<String, dynamic>.from(raw)),
  );
}
