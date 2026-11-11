import '../../../models/calibration/calibration_library_models.dart';
import '../../../models/collaboration/collaboration_models.dart'
    show ContributionConsent;
import '../../network_backend.dart';
import '../../roles/host_data/calibration_library.dart';

/// The calibration library of a linked host, over `/api/calibration-library`.
final class RemoteHostCalibrationLibrary implements CalibrationLibrary {
  RemoteHostCalibrationLibrary(this._host);

  final NetworkBackend _host;

  Future<List<CalibrationMasterRecord>> _fetch(
    CalibrationMasterType? type,
  ) async => [
    for (final row in await _host.getCalibrationMasters(
      type: type == null ? null : calibrationMasterTypeWireName(type),
    ))
      CalibrationMasterRecord.fromJson(row),
  ];

  // The host has already read its FITS headers, so [enrichFromHeaders] has
  // nothing left to do here.
  @override
  Future<List<CalibrationMasterRecord>> listMasters({
    CalibrationLibraryFilter filter = const CalibrationLibraryFilter(),
    bool enrichFromHeaders = true,
  }) async {
    final records = filter.whereCameraMatches(
      filter.whereStoredFieldsMatch(await _fetch(filter.type)),
    );
    return records..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<CalibrationMasterRecord?> getRecord(
    CalibrationMasterType type,
    int id,
  ) async {
    for (final record in await _fetch(type)) {
      if (record.type == type && record.id == id) return record;
    }
    return null;
  }

  // The host owns the masters, so it runs the matcher against its own
  // library with its own tolerances and hub.
  @override
  Future<CalibrationMatchSet> match(
    LightFrameContext context, {
    CalibrationMatchTolerances tolerances = CalibrationMatchTolerances.defaults,
    bool includeRemote = true,
  }) => _host.matchCalibrationMasters(context);

  @override
  Future<void> setTags(CalibrationMasterType type, int id, List<String> tags) =>
      _host.setCalibrationMasterTags(
        type: calibrationMasterTypeWireName(type),
        id: id,
        tags: [
          for (final tag in tags)
            if (tag.trim().isNotEmpty) tag.trim(),
        ],
      );

  @override
  Future<void> setNotes(CalibrationMasterType type, int id, String? notes) =>
      _host.setCalibrationMasterNotes(
        type: calibrationMasterTypeWireName(type),
        id: id,
        notes: notes?.trim(),
      );

  // A master the host does not have fails with its ServerError instead of
  // returning false; the caller reloads either way.
  @override
  Future<bool> deleteMaster(
    CalibrationMasterType type,
    int id, {
    bool deleteFile = false,
  }) async {
    await _host.deleteCalibrationMaster(
      type: calibrationMasterTypeWireName(type),
      id: id,
      deleteFile: deleteFile,
    );
    return true;
  }

  @override
  Future<void> publishMaster(
    CalibrationMasterRecord record, {
    required ContributionConsent consent,
  }) => _host.publishCalibrationMaster(
    type: calibrationMasterTypeWireName(record.type),
    id: record.id,
    license: consent.license.wireName,
    attributionName: consent.attributionName,
  );

  @override
  Future<void> retractPublishedMaster(CalibrationMasterRecord record) =>
      _host.retractCalibrationMaster(
        type: calibrationMasterTypeWireName(record.type),
        id: record.id,
      );

  @override
  Future<SharedMasterAcceptOutcome> acceptSharedMaster(
    CalibrationMasterRecord shared,
  ) async {
    final outcome = await _host.acceptRemoteCalibrationMaster(shared);
    return (
      kind: outcome['kind'] as String?,
      reason: outcome['reason'] as String?,
    );
  }

  @override
  HostFileDownload masterFileDownload(CalibrationMasterRecord record) =>
      (localPath, {onProgress}) => _host.downloadCalibrationMaster(
        type: calibrationMasterTypeWireName(record.type),
        id: record.id,
        localPath: localPath,
        onProgress: onProgress,
      );
}
