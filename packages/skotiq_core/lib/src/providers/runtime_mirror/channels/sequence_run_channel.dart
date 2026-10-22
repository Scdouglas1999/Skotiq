import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/sequence/sequence_models.dart';
import '../../sequence/node_exposure_tally.dart';
import '../../sequence/sequence_progress.dart';
import '../../sequence_stats_provider.dart' show currentRunIdProvider;
import '../../session_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

typedef SequenceRunSnapshot = ({
  SequenceProgress progress,
  Map<String, NodeExposureTally> tally,
  SessionState session,
});

final _sequenceRunSnapshotProvider = Provider<SequenceRunSnapshot>(
  (ref) => (
    progress: ref.watch(sequenceProgressProvider),
    tally: ref.watch(nodeExposureTallyProvider),
    session: ref.watch(sessionStateProvider),
  ),
);

/// What the host's run executor knows about the run in progress: which steps
/// finished and how, the frame tallies per step, and the session counters.
///
/// A client watching a run it did not start has only the run's lifecycle and
/// current-step events, so its step list showed nothing done and its session
/// counters stayed at zero. A client that started the run itself has its own
/// executor attached and keeps its own values.
class SequenceRunChannel extends RuntimeMirrorChannel<SequenceRunSnapshot> {
  const SequenceRunChannel();

  @override
  String get key => 'sequenceRun';

  @override
  get source => _sequenceRunSnapshotProvider;

  @override
  Duration get minInterval => const Duration(seconds: 1);

  @override
  Map<String, dynamic>? encode(SequenceRunSnapshot value) {
    final p = value.progress;
    final s = value.session;
    // Per-step percent and detail only for steps still running: finished
    // steps are read from their status, and the full maps grow all night.
    final running = {
      for (final e in p.nodeStatuses.entries)
        if (e.value == NodeStatus.running) e.key,
    };
    return {
      'progress': {
        'currentNodeId': p.currentNodeId,
        'currentNodeName': p.currentNodeName,
        'currentNodeStatus': p.currentNodeStatus?.name,
        'totalExposures': p.totalExposures,
        'completedExposures': p.completedExposures,
        'totalIntegrationSecs': finiteOrNull(p.totalIntegrationSecs),
        'completedIntegrationSecs': finiteOrNull(p.completedIntegrationSecs),
        'elapsedSecs': finiteOrNull(p.elapsedSecs),
        'estimatedRemainingSecs': finiteOrNull(p.estimatedRemainingSecs),
        'currentTarget': p.currentTarget,
        'currentFilter': p.currentFilter,
        'message': p.message,
        'nodeStatuses': {
          for (final e in p.nodeStatuses.entries) e.key: e.value.name,
        },
        'nodePercent': {
          for (final e in p.nodeProgressPercent.entries)
            if (running.contains(e.key) && finiteOrNull(e.value) != null)
              e.key: e.value,
        },
        'nodeDetail': {
          for (final e in p.nodeProgressDetail.entries)
            if (running.contains(e.key)) e.key: e.value,
        },
      },
      'tally': {
        for (final e in value.tally.entries)
          e.key: [e.value.captured, e.value.planned],
      },
      'session': {
        'isActive': s.isActive,
        'startTime': s.startTime?.toUtc().millisecondsSinceEpoch,
        'targetName': s.targetName,
        'targetRa': finiteOrNull(s.targetRa),
        'targetDec': finiteOrNull(s.targetDec),
        'totalExposures': s.totalExposures,
        'completedExposures': s.completedExposures,
        'failedExposures': s.failedExposures,
        'rejectedExposures': s.rejectedExposures,
        'totalIntegrationSecs': finiteOrNull(s.totalIntegrationSecs),
        'currentFilter': s.currentFilter,
        'isGuiding': s.isGuiding,
        'isCapturing': s.isCapturing,
        'isDithering': s.isDithering,
        'isAutofocusing': s.isAutofocusing,
        'avgHfr': finiteOrNull(s.avgHfr),
        'avgGuidingRmsRa': finiteOrNull(s.avgGuidingRmsRa),
        'avgGuidingRmsDec': finiteOrNull(s.avgGuidingRmsDec),
        'dbSessionId': s.dbSessionId,
      },
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || context.networkBackend == null) return;
    // A client that started the run has its own executor attached to it.
    if (context.read(currentRunIdProvider) != null) return;

    final progress = value['progress'];
    if (progress is Map) {
      NodeStatus? status(Object? name) =>
          NodeStatus.values.where((s) => s.name == name).firstOrNull;
      final statuses = <String, NodeStatus>{};
      final rawStatuses = progress['nodeStatuses'];
      if (rawStatuses is Map) {
        rawStatuses.forEach((id, name) {
          final parsed = status(name);
          if (id is String && parsed != null) statuses[id] = parsed;
        });
      }
      final percent = progress['nodePercent'];
      final detail = progress['nodeDetail'];
      context
          .read(sequenceProgressProvider.notifier)
          .mirrorHostProgress(
            SequenceProgress(
              currentNodeId: jsonString(progress['currentNodeId']),
              currentNodeName: jsonString(progress['currentNodeName']),
              currentNodeStatus: status(progress['currentNodeStatus']),
              totalExposures: requireInt(progress, 'totalExposures'),
              completedExposures: requireInt(progress, 'completedExposures'),
              totalIntegrationSecs: requireDouble(
                progress,
                'totalIntegrationSecs',
              ),
              completedIntegrationSecs: requireDouble(
                progress,
                'completedIntegrationSecs',
              ),
              elapsedSecs: requireDouble(progress, 'elapsedSecs'),
              estimatedRemainingSecs: jsonDouble(
                progress['estimatedRemainingSecs'],
              ),
              currentTarget: jsonString(progress['currentTarget']),
              currentFilter: jsonString(progress['currentFilter']),
              message: jsonString(progress['message']),
              nodeStatuses: statuses,
              nodeProgressPercent: {
                if (percent is Map)
                  for (final e in percent.entries)
                    if (e.key is String && e.value is num)
                      e.key as String: (e.value as num).toDouble(),
              },
              nodeProgressDetail: {
                if (detail is Map)
                  for (final e in detail.entries)
                    if (e.key is String && e.value is String)
                      e.key as String: e.value as String,
              },
            ),
          );
    }

    final tally = value['tally'];
    if (tally is Map) {
      context.read(nodeExposureTallyProvider.notifier).mirrorHostTally({
        for (final e in tally.entries)
          if (e.key is String &&
              e.value is List &&
              (e.value as List).length == 2)
            e.key as String: NodeExposureTally(
              captured: _countAt(e.value as List, 0),
              planned: _countAt(e.value as List, 1),
            ),
      });
    }

    final session = value['session'];
    if (session is Map) {
      context
          .read(sessionStateProvider.notifier)
          .mirrorHostSession(
            SessionState(
              isActive: session['isActive'] == true,
              startTime: jsonInstant(session['startTime'])?.toLocal(),
              targetName: jsonString(session['targetName']),
              targetRa: jsonDouble(session['targetRa']),
              targetDec: jsonDouble(session['targetDec']),
              totalExposures: requireInt(session, 'totalExposures'),
              completedExposures: requireInt(session, 'completedExposures'),
              failedExposures: requireInt(session, 'failedExposures'),
              rejectedExposures: requireInt(session, 'rejectedExposures'),
              totalIntegrationSecs: requireDouble(
                session,
                'totalIntegrationSecs',
              ),
              currentFilter: jsonString(session['currentFilter']),
              isGuiding: session['isGuiding'] == true,
              isCapturing: session['isCapturing'] == true,
              isDithering: session['isDithering'] == true,
              isAutofocusing: session['isAutofocusing'] == true,
              avgHfr: jsonDouble(session['avgHfr']),
              avgGuidingRmsRa: jsonDouble(session['avgGuidingRmsRa']),
              avgGuidingRmsDec: jsonDouble(session['avgGuidingRmsDec']),
              dbSessionId: jsonInt(session['dbSessionId']),
            ),
          );
    }
  }
}

int _countAt(List<dynamic> pair, int index) {
  final value = pair[index];
  if (value is num) return value.toInt();
  throw const FormatException('Tally count is not a number');
}
