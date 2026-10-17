part of '../imaging_records_repository.dart';

/// Map a `/api/sequence-runs` wire row onto the local Drift `SequenceRun`
/// shape the report builder reads. `statsJson` carries the mount/op counts
/// and error/warning lists the report parses; the snapshot column is not
/// exposed by the endpoint and the report does not read it.
db.SequenceRun _sequenceRunFromRemote(RemoteSequenceRun run) {
  return db.SequenceRun(
    id: run.id,
    sequenceId: run.sequenceId,
    sequenceName: run.sequenceName ?? 'Sequence',
    startedAt: run.startedAt,
    endedAt: run.endedAt,
    status: run.status,
    statsJson: run.statsJson ?? '{}',
    sequenceSnapshotJson: null,
  );
}

Map<String, dynamic> _companionToCreateJson(
  db.CapturedImagesCompanion companion,
) {
  T? read<T>(Value<T?> field) => field.present ? field.value : null;

  final capturedAt = read(companion.capturedAt);
  if (capturedAt == null) {
    throw ArgumentError(
      'capturedAt is required when creating a captured image',
    );
  }

  return {
    'filePath': read(companion.filePath)!,
    'fileName': read(companion.fileName)!,
    'fileFormat': read(companion.fileFormat) ?? 'fits',
    'fileSize': read(companion.fileSize),
    'sessionId': read(companion.sessionId),
    'targetId': read(companion.targetId),
    'frameType': read(companion.frameType)!,
    'exposureDuration': read(companion.exposureDuration)!,
    'gain': read(companion.gain),
    'offset': read(companion.offset),
    'binX': read(companion.binX) ?? 1,
    'binY': read(companion.binY) ?? 1,
    'filter': read(companion.filter),
    'sensorTemp': read(companion.sensorTemp),
    'coolerPower': read(companion.coolerPower),
    'hfr': read(companion.hfr),
    'starCount': read(companion.starCount),
    'background': read(companion.background),
    'noise': read(companion.noise),
    'qualityScore': read(companion.qualityScore),
    'guidingRmsRa': read(companion.guidingRmsRa),
    'guidingRmsDec': read(companion.guidingRmsDec),
    'guidingRmsTotal': read(companion.guidingRmsTotal),
    'mountRa': read(companion.mountRa),
    'mountDec': read(companion.mountDec),
    'mountAltitude': read(companion.mountAltitude),
    'mountAzimuth': read(companion.mountAzimuth),
    'pierSide': read(companion.pierSide),
    'focuserPosition': read(companion.focuserPosition),
    'focuserTemp': read(companion.focuserTemp),
    'rotatorAngle': read(companion.rotatorAngle),
    'isPlateSolved': read(companion.isPlateSolved) ?? false,
    'solvedRa': read(companion.solvedRa),
    'solvedDec': read(companion.solvedDec),
    'solvedRotation': read(companion.solvedRotation),
    'solvedPixelScale': read(companion.solvedPixelScale),
    'capturedAt': capturedAt.millisecondsSinceEpoch,
    'isAccepted': read(companion.isAccepted) ?? true,
    'rejectionReason': read(companion.rejectionReason),
  };
}

Stream<List<db.CapturedImage>> _pollRemoteSessionImages(
  NetworkBackend backend,
  int sessionId, {
  required Duration interval,
}) => _pollRemoteDistinct(
  () => _fetchRemoteSessionImages(backend, sessionId),
  listEquals,
  interval: interval,
);

Future<List<db.CapturedImage>> _fetchRemoteSessionImages(
  NetworkBackend backend,
  int sessionId,
) async {
  final rows = await backend.getSessionImageRows(sessionId);
  final mapped = rows.map(db.CapturedImage.fromJson).toList();
  mapped.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
  return mapped;
}

Stream<List<ProducingNodeThumbnail>> _pollRemoteProducingNodeThumbnails(
  NetworkBackend backend, {
  required String producingNodeId,
  String? producingRunId,
  int limit = 100,
  required Duration interval,
}) => _pollRemoteDistinct(
  () => _fetchRemoteProducingNodeThumbnails(
    backend,
    producingNodeId: producingNodeId,
    producingRunId: producingRunId,
    limit: limit,
  ),
  _thumbnailListsEqual,
  interval: interval,
);

Future<List<ProducingNodeThumbnail>> _fetchRemoteProducingNodeThumbnails(
  NetworkBackend backend, {
  required String producingNodeId,
  String? producingRunId,
  int limit = 100,
}) async {
  final rows = await backend.getImagesByProducingNode(
    producingNodeId,
    producingRunId: producingRunId,
    limit: limit,
  );
  return rows.map(_producingThumbnailFromApiJson).toList();
}

Stream<T> _pollRemoteDistinct<T>(
  Future<T> Function() fetch,
  bool Function(T previous, T next) unchanged, {
  required Duration interval,
}) => resilientDistinctPoll(
  fetch: fetch,
  unchanged: unchanged,
  interval: interval,
  onRetainedError: (error, stackTrace) {
    developer.log(
      'Remote imaging-record poll failed; retaining last value',
      name: 'ImagingRecordsRepository',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  },
);
