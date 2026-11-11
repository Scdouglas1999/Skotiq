import 'package:flutter/foundation.dart' show listEquals;

import '../../../database/database.dart' as db;
import '../../../services/imaging_records_repository.dart'
    show imagingSessionFromWireJson, wireTimestamp;
import '../../network_backend.dart';
import '../../roles/host_data/host_image_records.dart';
import '../../roles/host_data/host_records.dart';
import 'host_poll.dart';

/// Every list here also changes on the host's mutation events, which refresh
/// it at once; the poll is the safety net.
const _recordsPollInterval = Duration(seconds: 30);

/// The saved targets, sequences, sessions and runs of a linked host, as the
/// row types the local database yields.
final class RemoteHostRecords
    implements TargetLibrary, SequenceLibrary, SessionHistory, RunHistory {
  RemoteHostRecords(this._host);

  final NetworkBackend _host;
  final _poll = HostPoll('host records');

  Stream<List<T>> _watch<T>(Future<List<T>> Function() fetch) =>
      _poll.watch(fetch, listEquals, interval: _recordsPollInterval);

  @override
  Stream<List<db.Target>> watchAllTargets() => _watch(_fetchTargets);

  @override
  Stream<List<db.Target>> watchFavoriteTargets() => watchAllTargets().map(
    (targets) => targets.where((target) => target.isFavorite).toList(),
  );

  @override
  Stream<List<db.Sequence>> watchAllSequences() => _watch(() async {
    final rows = await _host.getSequenceList();
    return rows.map(_sequenceFromJson).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  });

  @override
  Stream<List<db.ImagingSession>> watchAllSessions() => _watch(() async {
    final sessions = await _host.getAllSessions();
    // Newest first, as locally: consumers read `.first` as the most recent.
    return sessions.map(imagingSessionFromWireJson).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
  });

  @override
  Stream<List<db.SequenceRun>> watchAllRuns() => _watch(_fetchRuns);

  @override
  Stream<List<db.SequenceRun>> watchRunsForSequence(int sequenceId) =>
      _watch(() => _fetchRuns(sequenceId: sequenceId));

  Future<List<db.Target>> _fetchTargets() async {
    final targets = await _host.getAllTargets();
    return targets.map(_targetFromJson).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<List<db.SequenceRun>> _fetchRuns({int? sequenceId}) async {
    final runs = await fetchAllRemoteSequenceRuns(
      _host,
      sequenceId: sequenceId,
    );
    // Newest first, as locally: consumers read `.first` as the newest run.
    return runs.map(_runFromRemote).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }
}

/// Polls the host's captured-image rows, newest capture first.
Stream<List<db.CapturedImage>> pollHostImageRows(HostImageRecords host) =>
    HostPoll('captured images').watch(
      () async {
        final images = await host.getAllImageRows();
        return images.map(db.CapturedImage.fromJson).toList()
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      },
      listEquals,
      interval: _recordsPollInterval,
    );

/// Fetches the complete host run history, following the paginated API until
/// every row reported by the host has been received. Keeping this helper
/// shared prevents reports and live history surfaces from quietly diverging
/// once an installation has accumulated more than one response page.
Future<List<RemoteSequenceRun>> fetchAllRemoteSequenceRuns(
  NetworkBackend backend, {
  int? sequenceId,
}) async {
  const pageSize = 1000;
  final runs = <RemoteSequenceRun>[];
  var offset = 0;

  while (true) {
    final page = await backend.fetchSequenceRuns(
      sequenceId: sequenceId,
      limit: pageSize,
      offset: offset,
    );
    runs.addAll(page.items);
    offset += page.items.length;
    if (page.items.isEmpty || offset >= page.total) break;
  }

  return runs;
}

db.SequenceRun _runFromRemote(RemoteSequenceRun run) {
  return db.SequenceRun(
    id: run.id,
    sequenceId: run.sequenceId,
    sequenceName: run.sequenceName ?? 'Sequence',
    startedAt: run.startedAt,
    endedAt: run.endedAt,
    status: run.status,
    statsJson: run.statsJson ?? '{}',
    // The wire row does not carry the executed-sequence snapshot (it is not
    // exposed by /api/sequence-runs); the run-history surfaces that consume
    // this stream do not read it, so leaving it null is lossless for them.
    sequenceSnapshotJson: null,
  );
}

db.Sequence _sequenceFromJson(Map<String, dynamic> json) {
  return db.Sequence(
    id: json['id'] as int,
    name: json['name'] as String? ?? 'Untitled sequence',
    description: json['description'] as String?,
    rootNodeId: json['rootNodeId'] as String?,
    estimatedDurationMins: json['estimatedDurationMins'] as int? ?? 0,
    createdAt: wireTimestamp(json['createdAt']),
    updatedAt: wireTimestamp(json['updatedAt']),
    isTemplate: json['isTemplate'] as bool? ?? false,
    tagsJson: json['tagsJson'] as String? ?? '[]',
    isFavorite: json['isFavorite'] as bool? ?? false,
  );
}

db.Target _targetFromJson(Map<String, dynamic> json) {
  return db.Target(
    id: json['id'] as int,
    name: json['name'] as String? ?? 'Untitled target',
    catalogId: json['catalogId'] as String?,
    objectType: json['objectType'] as String?,
    ra: (json['ra'] as num?)?.toDouble() ?? 0.0,
    dec: (json['dec'] as num?)?.toDouble() ?? 0.0,
    positionAngle: (json['positionAngle'] as num?)?.toDouble(),
    magnitude: (json['magnitude'] as num?)?.toDouble(),
    constellation: json['constellation'] as String?,
    sizeArcmin: (json['sizeArcmin'] as num?)?.toDouble(),
    minAltitude: (json['minAltitude'] as num?)?.toDouble() ?? 30.0,
    priority: json['priority'] as int? ?? 5,
    totalPlannedSubs: json['totalPlannedSubs'] as int? ?? 0,
    capturedSubs: json['capturedSubs'] as int? ?? 0,
    totalIntegrationSecs:
        (json['totalIntegrationSecs'] as num?)?.toDouble() ?? 0.0,
    goalIntegrationSecs:
        (json['goalIntegrationSecs'] as num?)?.toDouble() ?? 0.0,
    filterProgress: json['filterProgress'] as String?,
    notes: json['notes'] as String?,
    createdAt: wireTimestamp(json['createdAt']),
    updatedAt: wireTimestamp(json['updatedAt']),
    isFavorite: json['isFavorite'] as bool? ?? false,
  );
}
