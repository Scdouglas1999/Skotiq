import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/backend/sequencer_status.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../sequence/last_ended_run.dart';
import '../../sequence/run_record.dart';
import '../../sequence_stats_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

typedef RunRecordSnapshot = ({
  SequenceTerminalRunResult? terminal,
  CompletedImagingRun? imagingRun,
  LastEndedRun? lastEnded,
  DateTime? runStartedAt,
});

final _runRecordSnapshotProvider = Provider<RunRecordSnapshot>(
  (ref) => (
    terminal: ref.watch(sequenceTerminalRunResultProvider),
    imagingRun: ref.watch(completedImagingRunProvider),
    lastEnded: ref.watch(lastEndedRunProvider),
    runStartedAt: ref.watch(runStartedAtProvider),
  ),
);

/// Wire name of [RunRecordChannel].
const String runRecordChannelKey = 'runRecord';

/// What the host remembers about the run that ended: how it ended, which
/// session holds its frames, its counters, and when it started.
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
            },
      'runStartedAt': value.runStartedAt?.toUtc().millisecondsSinceEpoch,
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
        lastEnded = LastEndedRun(
          sequenceId: sequenceId,
          endedAt: endedAt.toLocal(),
        );
      }
    }

    context
        .read(runRecordProvider.notifier)
        .mirrorHostRunRecord(
          terminal: terminal,
          completedImagingRun: imagingRun,
          lastEnded: lastEnded,
          startedAt: jsonInstant(value['runStartedAt'])?.toLocal(),
        );
  }
}

Map<String, dynamic>? _encodeResult(SequenceTerminalRunResult? result) {
  if (result == null) return null;
  return {
    'generation': result.generation,
    'outcome': result.outcome.name,
    'runStatus': result.runStatus,
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
  final runStatus = jsonString(raw['runStatus']);
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
