// The seam [CalibrationLibraryService] folds remote shared masters in
// through.
//
// [RemoteCalibrationLibrary] is the small, HTTP-free interface the matcher
// depends on (query candidates / download-on-accept / publish), so the matcher
// stays unit-testable with a fake. [HubCalibrationLibrary] is the production
// implementation over [SharedCalibrationClient], resolving per-hub credentials
// the same way [ConstellationService] does.

import '../../models/calibration/calibration_library_models.dart';
import '../../models/calibration/shared_calibration_models.dart';
import '../../models/collaboration/collaboration_models.dart';
import '../constellation/constellation_models.dart';
import '../constellation/constellation_service.dart'
    show ConstellationCredentials;
import 'shared_calibration_client.dart';
import '../constellation/constellation_hub_key.dart';

/// The remote shared-calibration-library seam the local matcher folds in.
abstract class RemoteCalibrationLibrary {
  /// Whether a hub is actually configured/signed-in for this library.
  ///
  /// [queryCandidates] answers empty both when no hub is configured and when a
  /// reachable hub simply has nothing, and a signed-out rig is a NORMAL state,
  /// not a failure to raise. This is what lets the caller tell those apart and
  /// report that shared masters were not consulted.
  Future<bool> isConfigured();

  /// Candidate remote masters matching [context]'s sensor + capture tuple,
  /// already folded into the local [CalibrationMasterRecord] shape (each marked
  /// REMOTE via `remoteId`). The hub does the coarse sensor-keyed filter; the
  /// caller re-scores + applies the full quality gate. Returns empty when no
  /// hub is configured or when a reachable hub simply has no candidates; a hub
  /// that is unreachable or rejects the query throws (typically a
  /// [ConstellationException]) so the caller can tell offline apart from empty.
  Future<List<CalibrationMasterRecord>> queryCandidates(
    LightFrameContext context,
  );

  /// Download a chosen remote master (download-on-accept): its bytes AND the
  /// hub's authoritative record of the tuple those bytes were published under.
  /// [record] must be a REMOTE record (carry a `remoteId`) — only its
  /// `remoteId` is used to address the download, never its metadata, because
  /// the caller's copy of that metadata is untrusted.
  Future<SharedCalibrationDownload> downloadMaster(
    CalibrationMasterRecord record,
  );

  /// Publish a LOCAL master to the configured hub under [consent]'s license.
  /// [record] must have an on-disk [CalibrationMasterRecord.filePath]; the
  /// caller-built [provenance] carries the trust signals (frame count, dark
  /// current, sensor dimensions). Throws [StateError] when [consent] does not
  /// permit sharing (its license is `private`).
  Future<SharedCalibrationMaster> publish({
    required CalibrationMasterRecord record,
    required ContributionConsent consent,
    Provenance provenance,
  });

  /// Retract (un-share) a master the user previously published to the hub.
  /// [remoteId] is the hub master id returned by [publish]
  /// ([SharedCalibrationMaster.id]); only the owner (or an admin) may retract.
  Future<void> retract(String remoteId);
}

/// Builds a [SharedCalibrationClient] from resolved credentials. Injectable so
/// the hub-backed library can be exercised with a MockClient.
typedef SharedCalibrationClientFactory =
    SharedCalibrationClient Function(ConstellationCredentials credentials);

/// Production [RemoteCalibrationLibrary] over a Skotiq hub.
class HubCalibrationLibrary implements RemoteCalibrationLibrary {
  HubCalibrationLibrary({
    required Future<ConstellationCredentials?> Function() credentialsResolver,
    SharedCalibrationClientFactory? clientFactory,
  }) : _credentialsResolver = credentialsResolver,
       _clientFactory = clientFactory ?? _defaultClientFactory;

  final Future<ConstellationCredentials?> Function() _credentialsResolver;
  final SharedCalibrationClientFactory _clientFactory;

  static SharedCalibrationClient _defaultClientFactory(
    ConstellationCredentials c,
  ) => SharedCalibrationClient(
    hubBaseUrl: c.hubBaseUrl,
    bearerToken: c.bearerToken,
  );

  @override
  Future<bool> isConfigured() async => await _credentialsResolver() != null;

  @override
  Future<List<CalibrationMasterRecord>> queryCandidates(
    LightFrameContext context,
  ) async {
    final creds = await _credentialsResolver();
    if (creds == null) return const [];
    final client = _clientFactory(creds);
    final key = constellationHubKey(creds.hubBaseUrl);
    try {
      final masters = await client.queryMasters(context);
      final records = <CalibrationMasterRecord>[];
      for (final m in masters) {
        final record = m.toMasterRecord(key);
        if (record != null) records.add(record);
      }
      return records;
    } finally {
      client.close();
    }
  }

  @override
  Future<SharedCalibrationDownload> downloadMaster(
    CalibrationMasterRecord record,
  ) async {
    final remoteId = record.remoteId;
    if (remoteId == null) {
      throw StateError('downloadMaster requires a remote record (remoteId)');
    }
    final creds = await _credentialsResolver();
    if (creds == null) {
      throw const ConstellationException(
        'No hub is configured. Sign in to a hub first.',
        kind: ConstellationErrorKind.auth,
      );
    }
    final client = _clientFactory(creds);
    try {
      return await client.downloadMasterBytes(remoteId);
    } finally {
      client.close();
    }
  }

  @override
  Future<SharedCalibrationMaster> publish({
    required CalibrationMasterRecord record,
    required ContributionConsent consent,
    Provenance provenance = const Provenance(),
  }) async {
    if (!consent.permitsSharing) {
      throw StateError(
        'consent does not permit sharing (license ${consent.license.wireName})',
      );
    }
    final filePath = record.filePath;
    if (filePath == null || filePath.isEmpty) {
      throw StateError('publish requires a local master file path');
    }
    final cameraModel = provenance.cameraModel ?? record.cameraId;
    final sensorWidth = provenance.sensorWidth ?? record.width;
    final sensorHeight = provenance.sensorHeight ?? record.height;
    final frameCount = provenance.frameCount ?? record.frameCount;
    final missingMetadata = <String>[
      if (cameraModel == null || cameraModel.trim().isEmpty) 'camera model',
      if (sensorWidth == null || sensorWidth <= 0) 'sensor width',
      if (sensorHeight == null || sensorHeight <= 0) 'sensor height',
      if (record.gain == null) 'gain',
      if (record.offset == null) 'offset',
      if (record.exposureSeconds == null) 'exposure',
      if (frameCount == null || frameCount <= 0) 'frame count',
    ];
    if (missingMetadata.isNotEmpty) {
      throw StateError(
        'publish requires complete calibration matching metadata; missing: '
        '${missingMetadata.join(', ')}',
      );
    }
    final creds = await _credentialsResolver();
    if (creds == null) {
      throw const ConstellationException(
        'No hub is configured. Sign in to a hub first.',
        kind: ConstellationErrorKind.auth,
      );
    }
    final client = _clientFactory(creds);
    try {
      // Stamp the trust signals from the record when the caller did not supply
      // them explicitly, and the consented attribution name as the credit.
      final prov = provenance.copyWith(
        frameCount: provenance.frameCount ?? record.frameCount,
        sensorWidth: provenance.sensorWidth ?? record.width,
        sensorHeight: provenance.sensorHeight ?? record.height,
        cameraModel: provenance.cameraModel ?? record.cameraId,
        displayName: provenance.displayName ?? consent.attributionName,
      );
      return await client.publishMaster(
        masterType: calibrationMasterTypeWireName(record.type),
        cameraModel: cameraModel!,
        license: consent.license,
        filePath: filePath,
        provenance: prov,
        sensorWidth: sensorWidth!,
        sensorHeight: sensorHeight!,
        gain: record.gain!,
        offset: record.offset!,
        exposureSeconds: record.exposureSeconds!,
        temperatureC: record.temperature,
        binX: record.binX,
        binY: record.binY,
        filter: record.filter,
        opticalTrain: record.opticalTrainId,
        frameCount: frameCount!,
        darkCurrent: provenance.darkCurrent,
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<void> retract(String remoteId) async {
    final creds = await _credentialsResolver();
    if (creds == null) {
      throw const ConstellationException(
        'No hub is configured. Sign in to a hub first.',
        kind: ConstellationErrorKind.auth,
      );
    }
    final client = _clientFactory(creds);
    try {
      await client.deleteMaster(remoteId);
    } finally {
      client.close();
    }
  }
}
