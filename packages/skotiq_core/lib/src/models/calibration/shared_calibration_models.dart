// Wire-level model for the shared calibration library hub endpoints
// (`/v1/calibration/masters`).
//
// [SharedCalibrationMaster] decodes one published master the hub returns from a
// query, and [toMasterRecord] folds it into the same [CalibrationMasterRecord]
// the local matcher ranks — carrying its REMOTE provenance (frame count, dark
// current, sensor dimensions, authoritative producer + license) so the user can
// trust what they pull and the quality gate can refuse a sensor/dimension
// mismatch. Field names mirror the hub's `SharedCalibrationMasterRow.toJson`.

import '../collaboration/collaboration_models.dart';
import 'calibration_library_models.dart';

/// One shared master-calibration artifact published to a hub.
class SharedCalibrationMaster {
  const SharedCalibrationMaster({
    required this.id,
    required this.accountId,
    required this.masterType,
    required this.cameraModel,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.gain,
    required this.offset,
    required this.exposureSeconds,
    this.temperatureC,
    required this.binX,
    required this.binY,
    this.filter,
    this.opticalTrain,
    required this.frameCount,
    this.darkCurrent,
    required this.license,
    required this.provenance,
    required this.bytes,
    required this.createdAt,
  });

  /// Hub master id (the handle download / delete act on).
  final String id;

  /// Authoritative producer account id (the trustworthy "who shot this" key).
  final String accountId;

  /// Wire master-type name (`dark` | `bias` | `flat`).
  final String masterType;

  final String cameraModel;
  final int sensorWidth;
  final int sensorHeight;
  final int gain;
  final int offset;
  final double exposureSeconds;
  final double? temperatureC;
  final int binX;
  final int binY;
  final String? filter;
  final String? opticalTrain;
  final int frameCount;
  final double? darkCurrent;
  final ContributionLicense license;
  final Provenance provenance;
  final int bytes;
  final DateTime createdAt;

  factory SharedCalibrationMaster.fromJson(Map<String, dynamic> json) {
    final provRaw = json['provenanceJson'];
    final provenance = provRaw is String
        ? Provenance.fromJsonString(provRaw)
        : (json['provenance'] is Map
              ? Provenance.fromJson(
                  (json['provenance'] as Map).cast<String, dynamic>(),
                )
              : const Provenance());
    return SharedCalibrationMaster(
      id: json['id'] as String? ?? '',
      accountId: json['accountId'] as String? ?? '',
      masterType: json['masterType'] as String? ?? 'dark',
      cameraModel: json['cameraModel'] as String? ?? '',
      sensorWidth: (json['sensorWidth'] as num?)?.toInt() ?? 0,
      sensorHeight: (json['sensorHeight'] as num?)?.toInt() ?? 0,
      gain: (json['gain'] as num?)?.toInt() ?? 0,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      exposureSeconds: (json['exposureSeconds'] as num?)?.toDouble() ?? 0.0,
      temperatureC: (json['temperatureC'] as num?)?.toDouble(),
      binX: (json['binX'] as num?)?.toInt() ?? 1,
      binY: (json['binY'] as num?)?.toInt() ?? 1,
      filter: json['filter'] as String?,
      opticalTrain: json['opticalTrain'] as String?,
      frameCount: (json['frameCount'] as num?)?.toInt() ?? 0,
      darkCurrent: (json['darkCurrent'] as num?)?.toDouble(),
      // An unknown/missing license fails closed to `private` (non-shareable), so
      // a corrupt or forward-version value denies reuse rather than widening it.
      license: ContributionLicense.fromWire(json['license'] as String?),
      provenance: provenance,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse('${json['createdAt']}')?.toLocal() ??
          DateTime.now(),
    );
  }

  /// The [CalibrationMasterType] this master targets, or null when the wire name
  /// is unknown (a future type this client cannot calibrate with).
  CalibrationMasterType? get type => calibrationMasterTypeFromWire(masterType);

  /// Fold this remote master into the local matcher's record shape. The synthetic
  /// `id` is 0 (the durable identity is [id] via `remoteId`); [filePath] is null
  /// until downloaded on accept. Provenance + license ride along so the matcher
  /// can surface trust signals and the quality gate can refuse a mismatch.
  CalibrationMasterRecord? toMasterRecord(String hubKey) {
    final resolvedType = type;
    if (resolvedType == null) return null;
    return CalibrationMasterRecord(
      type: resolvedType,
      id: 0,
      filePath: null,
      isMaster: true,
      frameCount: frameCount > 0 ? frameCount : null,
      exposureSeconds: exposureSeconds,
      temperature: temperatureC,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      filter: filter,
      flatKind: null,
      width: sensorWidth > 0 ? sensorWidth : null,
      height: sensorHeight > 0 ? sensorHeight : null,
      cameraId: cameraModel.isEmpty ? null : cameraModel,
      opticalTrainId: opticalTrain,
      createdAt: createdAt,
      remoteId: id,
      sourceHubKey: hubKey,
      provenance: provenance,
      license: license,
      sharedBy: provenance.displayName,
    );
  }
}
