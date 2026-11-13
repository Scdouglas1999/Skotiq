import 'package:flutter/foundation.dart' show listEquals;
import 'package:skotiq_remote_protocol/wire_models.dart';

import '../../../database/database.dart' show PolarAlignmentHistoryEntry;
import '../../roles/host_data/host_history.dart';
import '../../roles/host_data/polar_alignment_log.dart';
import 'host_poll.dart';

/// The polar alignments a linked host has recorded. A client never runs the
/// alignment loop, so its own table holds none.
final class RemotePolarAlignmentLog implements PolarAlignmentLog {
  RemotePolarAlignmentLog(this._host);

  final HostHistory _host;
  final _poll = HostPoll('polar alignment history');

  @override
  Future<List<PolarAlignmentHistoryEntry>> getHistoryForProfile(
    int? profileId, {
    int limit = 20,
  }) async {
    final page = await _host.fetchPolarAlignmentHistory(
      equipmentProfileId: profileId,
    );
    final entries = page.items.map(_entryFromRemote).toList()
      ..sort((a, b) => b.completedAt.compareTo(a.completedAt));
    return entries.take(limit).toList();
  }

  @override
  Future<PolarAlignmentHistoryEntry?> getLastAlignment(int? profileId) async =>
      (await getHistoryForProfile(profileId, limit: 1)).firstOrNull;

  @override
  Stream<List<PolarAlignmentHistoryEntry>> watchHistory(
    int? profileId, {
    int limit = 20,
  }) => _poll.watch(
    () => getHistoryForProfile(profileId, limit: limit),
    listEquals,
  );
}

PolarAlignmentHistoryEntry _entryFromRemote(
  RemotePolarAlignmentHistoryEntry row,
) => PolarAlignmentHistoryEntry(
  id: row.id,
  equipmentProfileId: row.equipmentProfileId,
  initialAzimuthError: row.initialAzimuthError ?? 0.0,
  initialAltitudeError: row.initialAltitudeError ?? 0.0,
  initialTotalError: row.initialTotalError ?? 0.0,
  finalAzimuthError: row.finalAzimuthError ?? 0.0,
  finalAltitudeError: row.finalAltitudeError ?? 0.0,
  finalTotalError: row.finalTotalError ?? 0.0,
  startedAt: row.startedAt,
  completedAt: row.completedAt,
  autoCompleted: row.autoCompleted,
  isNorth: row.isNorth,
  configJson: row.configJson ?? '{}',
);
