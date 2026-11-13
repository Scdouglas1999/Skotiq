import '../../../models/imaging/session_status.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show listEquals;

import '../../../database/daos/images_dao.dart'
    show ProducingNodeThumbnail, StoredWcsDistortion;
import '../../../database/database.dart' as db;
import '../../roles/host_data/host_imaging_records.dart';
import '../../roles/host_data/imaging_records.dart';
import 'host_poll.dart';
import 'wire_rows.dart';

/// The sessions and captured-image rows of a linked host, read and written
/// through its API.
final class RemoteImagingRecords implements ImagingRecords {
  RemoteImagingRecords(
    this._host, {
    Duration pollInterval = HostPoll.defaultInterval,
  }) : _pollInterval = pollInterval;

  final HostImagingRecords _host;
  final Duration _pollInterval;
  final _poll = HostPoll('imaging records');

  @override
  Future<List<db.ImagingSession>> getAllSessions() async {
    final rows = await _host.getAllSessions();
    return rows.map(imagingSessionFromWireJson).toList();
  }

  @override
  Future<db.ImagingSession?> getSessionById(int id) async {
    final row = await _host.getSessionById(id);
    return row == null ? null : imagingSessionFromWireJson(row);
  }

  @override
  Future<List<db.ImagingSession>> getSessionsForTarget(int targetId) async {
    final rows = await _host.getSessionsForTarget(targetId);
    return rows.map(imagingSessionFromWireJson).toList();
  }

  @override
  Future<int> startSession({
    String? name,
    int? profileId,
    int? targetId,
    int? sequenceId,
  }) => _host.createSession({
    if (name != null) 'name': name,
    if (profileId != null) 'profileId': profileId,
    if (targetId != null) 'targetId': targetId,
    if (sequenceId != null) 'sequenceId': sequenceId,
  });

  @override
  Future<void> endSession(
    int id, {
    SessionStatus status = SessionStatus.completed,
  }) => _host.endSession(id, status: status);

  /// The host sweeps its own sessions when it opens and when a sequence
  /// starts; a client closing them would be a second, blind writer of a
  /// liveness claim only the host can make.
  @override
  Future<List<int>> closeOrphanedSessions({required String cause}) async =>
      const <int>[];

  /// The host owns the recovery that re-opens its session.
  @override
  Future<void> reopenSession(int id) async {}

  /// The equipment worth restoring is the host's, which its own executor
  /// records.
  @override
  Future<void> updateEquipmentSnapshot(int id, String snapshotJson) async {}

  /// The host closes the session against its own rows, so the end time is
  /// dated there.
  @override
  Future<void> abortSession(int id) =>
      _host.endSession(id, status: SessionStatus.aborted);

  @override
  Future<void> updateSessionStats(
    int id, {
    int? totalExposures,
    int? successfulExposures,
    int? failedExposures,
    double? totalIntegrationSecs,
    double? avgHfr,
    double? avgGuidingRms,
    int? autofocusCount,
  }) => _host.updateSession(id, {
    if (totalExposures != null) 'totalExposures': totalExposures,
    if (successfulExposures != null) 'successfulExposures': successfulExposures,
    if (failedExposures != null) 'failedExposures': failedExposures,
    if (totalIntegrationSecs != null)
      'totalIntegrationSecs': totalIntegrationSecs,
    if (avgHfr != null) 'avgHfr': avgHfr,
    if (avgGuidingRms != null) 'avgGuidingRms': avgGuidingRms,
    if (autofocusCount != null) 'autofocusCount': autofocusCount,
  });

  @override
  Future<void> updateSessionNotes(int id, String notes) =>
      _host.updateSession(id, {'notes': notes});

  @override
  Future<db.DbCapturedImage?> getImageById(int id) async {
    final row = await _host.getCapturedImageById(id);
    return row == null ? null : db.DbCapturedImage.fromJson(row);
  }

  @override
  Future<List<db.DbCapturedImage>> getImagesForSession(int sessionId) async {
    final rows = await _host.getSessionImageRows(sessionId);
    return rows.map(db.DbCapturedImage.fromJson).toList();
  }

  @override
  Future<List<db.DbCapturedImage>> getImagesForTarget(int targetId) async {
    final rows = await _host.getImagesForTarget(targetId);
    return rows.map(db.DbCapturedImage.fromJson).toList();
  }

  @override
  Future<List<db.DbCapturedImage>> getRecentImagesForSession(
    int sessionId, {
    int limit = 5,
    DateTime? atOrBefore,
  }) async {
    final rows = await _host.getSessionImageRows(sessionId);
    final images =
        rows
            .map(db.DbCapturedImage.fromJson)
            .where(
              (image) =>
                  atOrBefore == null || !image.capturedAt.isAfter(atOrBefore),
            )
            .toList()
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    return images.length <= limit ? images : images.sublist(0, limit);
  }

  @override
  Stream<List<db.DbCapturedImage>> watchImagesForSession(int sessionId) =>
      _poll.watch(
        () async {
          final rows = await _host.getSessionImageRows(sessionId);
          return rows.map(db.DbCapturedImage.fromJson).toList()
            ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
        },
        listEquals,
        interval: _pollInterval,
      );

  @override
  Future<int> createImage(db.CapturedImagesCompanion image) =>
      _host.createCapturedImage(_companionToCreateJson(image));

  @override
  void scheduleThumbnail({required int imageId, required String fitsPath}) {}

  @override
  Future<void> updateImageFilePath(int id, String filePath) =>
      _host.updateCapturedImage(id, {'filePath': filePath});

  @override
  Future<void> rejectImage(int id, String reason) => _host.updateCapturedImage(
    id,
    {'isAccepted': false, 'rejectionReason': reason},
  );

  @override
  Future<void> acceptImage(int id) => _host.updateCapturedImage(id, {
    'isAccepted': true,
    'rejectionReason': null,
  });

  @override
  Future<void> updatePlateSolveResult(
    int id, {
    required double solvedRa,
    required double solvedDec,
    required double solvedRotation,
    required double solvedPixelScale,
    double? solvedCd1_1,
    double? solvedCd1_2,
    double? solvedCd2_1,
    double? solvedCd2_2,
    String? solvedSip,
  }) {
    final hasCd =
        solvedCd1_1 != null &&
        solvedCd1_2 != null &&
        solvedCd2_1 != null &&
        solvedCd2_2 != null;
    return _host.updateCapturedImage(id, {
      'isPlateSolved': true,
      'solvedRa': solvedRa,
      'solvedDec': solvedDec,
      'solvedRotation': solvedRotation,
      'solvedPixelScale': solvedPixelScale,
      if (hasCd) 'solvedCd1_1': solvedCd1_1,
      if (hasCd) 'solvedCd1_2': solvedCd1_2,
      if (hasCd) 'solvedCd2_1': solvedCd2_1,
      if (hasCd) 'solvedCd2_2': solvedCd2_2,
      if (hasCd) 'solvedSip': solvedSip,
    });
  }

  /// The host folds its own graded frames into its atlas.
  @override
  void notifyGradedFrame(int id) {}

  @override
  Future<StoredWcsDistortion?> getStoredWcsDistortion(int id) async => null;

  @override
  Future<void> stampProducingNode({
    required int imageId,
    String? producingNodeId,
    String? producingRunId,
    String? runtimeGrade,
    double? eccentricity,
    double? fwhm,
  }) => _host.updateCapturedImage(imageId, {
    if (producingNodeId != null) 'producingNodeId': producingNodeId,
    if (producingRunId != null) 'producingRunId': producingRunId,
    if (runtimeGrade != null) 'runtimeGrade': runtimeGrade,
    if (eccentricity != null) 'eccentricity': eccentricity,
    if (fwhm != null) 'fwhm': fwhm,
  });

  @override
  Future<List<ProducingNodeThumbnail>> getImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) async {
    final rows = await _host.getImagesByProducingNode(
      producingNodeId,
      producingRunId: producingRunId,
      limit: limit,
    );
    return rows.map(_producingThumbnailFromApiJson).toList();
  }

  @override
  Stream<List<ProducingNodeThumbnail>> watchImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
    int limit = 100,
  }) => _poll.watch(
    () => getImagesByProducingNode(
      producingNodeId: producingNodeId,
      producingRunId: producingRunId,
      limit: limit,
    ),
    _thumbnailListsEqual,
    interval: _pollInterval,
  );

  @override
  Future<int> countImagesByProducingNode({
    required String producingNodeId,
    String? producingRunId,
  }) async {
    final rows = await _host.getImagesByProducingNode(
      producingNodeId,
      producingRunId: producingRunId,
    );
    return rows.length;
  }
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

bool _thumbnailListsEqual(
  List<ProducingNodeThumbnail> previous,
  List<ProducingNodeThumbnail> next,
) {
  if (identical(previous, next)) return true;
  if (previous.length != next.length) return false;
  for (var index = 0; index < previous.length; index++) {
    final a = previous[index];
    final b = next[index];
    if (a.id != b.id ||
        a.filePath != b.filePath ||
        a.fileName != b.fileName ||
        a.filter != b.filter ||
        a.frameType != b.frameType ||
        a.hfr != b.hfr ||
        a.eccentricity != b.eccentricity ||
        a.fwhm != b.fwhm ||
        a.starCount != b.starCount ||
        a.exposureDuration != b.exposureDuration ||
        a.capturedAt != b.capturedAt ||
        a.isAccepted != b.isAccepted ||
        a.rejectionReason != b.rejectionReason ||
        a.runtimeGrade != b.runtimeGrade ||
        a.producingNodeId != b.producingNodeId ||
        a.producingRunId != b.producingRunId) {
      return false;
    }
  }
  return true;
}

ProducingNodeThumbnail _producingThumbnailFromApiJson(
  Map<String, dynamic> json,
) {
  final image = db.DbCapturedImage.fromJson(json);
  return ProducingNodeThumbnail(
    id: image.id,
    filePath: image.filePath,
    fileName: image.fileName,
    filter: image.filter,
    frameType: image.frameType,
    hfr: image.hfr,
    eccentricity: (json['eccentricity'] as num?)?.toDouble(),
    fwhm: (json['fwhm'] as num?)?.toDouble(),
    starCount: image.starCount,
    exposureDuration: image.exposureDuration,
    capturedAt: image.capturedAt,
    isAccepted: image.isAccepted,
    rejectionReason: image.rejectionReason,
    runtimeGrade: json['runtimeGrade'] as String?,
    producingNodeId: json['producingNodeId'] as String? ?? '',
    producingRunId: json['producingRunId'] as String?,
  );
}
