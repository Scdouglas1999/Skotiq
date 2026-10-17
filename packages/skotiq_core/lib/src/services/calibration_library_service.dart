import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../database/daos/calibration_tags_dao.dart';
import '../database/daos/flat_library_dao.dart';
import '../database/database.dart';
import '../models/calibration/calibration_library_models.dart';
import '../models/calibration/shared_calibration_models.dart';
import '../models/collaboration/collaboration_models.dart';
import '../providers/backend_provider.dart';
import '../providers/constellation_provider.dart';
import '../providers/database_provider.dart';
import 'calibration/fits_header_reader.dart';
import 'calibration/shared_calibration_library.dart';
import '../utils/skotiq_data_directory.dart';
part 'calibration_library_service/remote_acceptance.dart';
part 'calibration_library_service/matchers.dart';
part 'calibration_library_service/sharing.dart';
part 'calibration_library_service/loading.dart';
part 'calibration_library_service/formatting.dart';

/// The Calibration Library Manager service: one unified browse / tag /
/// auto-match surface over the master artifacts the imaging pipeline already
/// records — `dark_library` (darks + biases), `flat_library` (master flats),
/// and `defect_maps` — joined with the v46 `calibration_tags` annotations.
///
/// Three jobs:
///  1. **List** masters with independent filters ([listMasters]), enriching
///     metadata the DB rows lack (camera id, temperature, filter) from the
///     FITS primary header and caching the camera id in `calibration_tags`.
///  2. **Match** ([match]): given a light-frame context, pick the best master
///     per type with a transparent 0–100 score, per-pick reasons, and
///     warnings (exact gain/offset required for darks; temperature within
///     tolerance; nearest exposure with a scaling flag; flats by filter +
///     recency; staleness thresholds per type).
///  3. **Annotate / manage**: user tags + notes per master ([setTags] /
///     [setNotes]) and deletion of the artifact row + optional file
///     ([deleteMaster]).
class CalibrationLibraryService {
  CalibrationLibraryService({
    required SkotiqDatabase db,
    required FlatLibraryDao flatLibraryDao,
    required CalibrationTagsDao tagsDao,
    Ref? ref,
    this.headerReader = const FitsHeaderReader(),
    this.thresholds = CalibrationStalenessThresholds.defaults,
    RemoteCalibrationLibrary? remoteLibrary,
    SkotiqBackend? backend,
    Future<String> Function()? sharedMasterDirResolver,
    DateTime Function()? now,
  }) : _db = db,
       _flatDao = flatLibraryDao,
       _tagsDao = tagsDao,
       _backend = backend ?? ref?.read(backendProvider),
       _backendNotifier = ref?.read(backendProvider.notifier),
       _remoteLibrary = remoteLibrary,
       _sharedMasterDirResolver = sharedMasterDirResolver,
       _now = now ?? DateTime.now;

  final SkotiqDatabase _db;
  final FlatLibraryDao _flatDao;
  final CalibrationTagsDao _tagsDao;
  final SkotiqBackend? _backend;
  final BackendNotifier? _backendNotifier;
  bool _retired = false;

  /// The hub-backed shared calibration library. When set, [match] folds
  /// ranked REMOTE candidates into the local ranking and [acceptRemoteMaster]
  /// can download + merge a chosen one. Null on a remote client (the appliance
  /// owns matching) and in wirings without a hub.
  final RemoteCalibrationLibrary? _remoteLibrary;

  /// Resolves the directory accepted remote masters are downloaded into. Null in
  /// wirings that never accept remote masters; [acceptRemoteMaster] then refuses
  /// rather than guessing a path.
  final Future<String> Function()? _sharedMasterDirResolver;

  final FitsHeaderReader headerReader;
  final CalibrationStalenessThresholds thresholds;
  final DateTime Function() _now;

  /// The active [NetworkBackend] when this device is a remote client (a tablet
  /// or desktop driving the headless appliance). When non-null, tag/note/
  /// delete/match operations target the APPLIANCE's real calibration library
  /// over `/api/calibration-library/*` instead of this device's local Drift
  /// DB (which on a remote client is empty). Null on the host / local builds,
  /// where the operations run against the local DB.
  NetworkBackend? get _remote {
    final backend = _backend;
    return backend is NetworkBackend ? backend : null;
  }

  bool get _hasAuthority {
    final backend = _backend;
    if (backend == null) return true;
    return !_retired && (_backendNotifier?.isCurrentBackend(backend) ?? false);
  }

  void retire() => _retired = true;

  void _ensureAuthority() {
    if (_hasAuthority) return;
    throw StateError(
      'The imaging host changed while the calibration library was loading. '
      'The stale result was discarded; try again on the current host.',
    );
  }

  // Listing + enrichment

  /// All library records matching [filter], newest first.
  ///
  /// When [enrichFromHeaders] is set (the default), records missing a camera
  /// id / temperature / filter get those keys read from the FITS primary
  /// header of the master file; the camera id is cached in
  /// `calibration_tags.camera_id` so each file is parsed at most once.
  /// Enrichment is best-effort — a missing or malformed file never breaks the
  /// listing.
  Future<List<CalibrationMasterRecord>> listMasters({
    CalibrationLibraryFilter filter = const CalibrationLibraryFilter(),
    bool enrichFromHeaders = true,
  }) async {
    _ensureAuthority();
    final remote = _remote;
    var records = remote == null
        ? await _loadAll()
        : [
            for (final row in await remote.getCalibrationMasters(
              type: filter.type == null
                  ? null
                  : calibrationMasterTypeWireName(filter.type!),
            ))
              CalibrationMasterRecord.fromJson(row),
          ];
    _ensureAuthority();

    if (filter.mastersOnly) {
      records = records.where((r) => r.isMaster).toList();
    }
    if (filter.type != null) {
      records = records.where((r) => r.type == filter.type).toList();
    }
    if (filter.gain != null) {
      records = records.where((r) => r.gain == filter.gain).toList();
    }
    if (filter.binX != null) {
      records = records.where((r) => r.binX == filter.binX).toList();
    }
    if (filter.binY != null) {
      records = records.where((r) => r.binY == filter.binY).toList();
    }
    if (filter.exposureSeconds != null) {
      records = records
          .where(
            (r) =>
                r.exposureSeconds != null &&
                (r.exposureSeconds! - filter.exposureSeconds!).abs() <=
                    filter.exposureToleranceSecs,
          )
          .toList();
    }
    if (filter.temperatureMin != null) {
      records = records
          .where(
            (r) =>
                r.temperature != null &&
                r.temperature! >= filter.temperatureMin!,
          )
          .toList();
    }
    if (filter.temperatureMax != null) {
      records = records
          .where(
            (r) =>
                r.temperature != null &&
                r.temperature! <= filter.temperatureMax!,
          )
          .toList();
    }
    final filterName = filter.filter?.trim();
    if (filterName != null && filterName.isNotEmpty) {
      records = records
          .where(
            (r) =>
                r.filter != null &&
                r.filter!.trim().toLowerCase() == filterName.toLowerCase(),
          )
          .toList();
    }

    if (enrichFromHeaders && remote == null) {
      records = await _enrichAll(records);
      _ensureAuthority();
    }

    final cameraId = filter.cameraId?.trim();
    if (cameraId != null && cameraId.isNotEmpty) {
      records = records.where((r) => r.cameraId == cameraId).toList();
    }

    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _ensureAuthority();
    return records;
  }

  /// One record by identity, or null. Enriched from the FITS header.
  Future<CalibrationMasterRecord?> getRecord(
    CalibrationMasterType type,
    int id,
  ) async {
    _ensureAuthority();
    final remote = _remote;
    final all = remote == null
        ? await _loadAll()
        : [
            for (final row in await remote.getCalibrationMasters(
              type: calibrationMasterTypeWireName(type),
            ))
              CalibrationMasterRecord.fromJson(row),
          ];
    _ensureAuthority();
    for (final record in all) {
      if (record.type == type && record.id == id) {
        if (remote != null) return record;
        final enriched = await _enrich(record);
        _ensureAuthority();
        return enriched;
      }
    }
    return null;
  }

  // Matching

  /// Pick the best master per type for [context].
  ///
  /// Rules (each deviation is scored down and surfaced in `reasons` /
  /// `warnings` — the match is transparent by design):
  ///  * **Darks**: gain, offset, and binning must match *exactly*. Exposure
  ///    within ±[CalibrationMatchTolerances.dark]`.exposureSecs` is an exact
  ///    match; otherwise the nearest-exposure dark is returned with
  ///    `exposureScaled = true` and a warning. Temperature within tolerance
  ///    preferred; out-of-tolerance candidates only win when nothing closer
  ///    exists (with a warning). Stacked masters beat raw frames. Older than
  ///    [CalibrationStalenessThresholds.darkStaleDays] warns.
  ///  * **Bias**: exact gain / offset / binning; newest wins.
  ///  * **Flats**: matched by filter (exact, when the context has one) +
  ///    recency; gain / offset / binning exact (mirrors
  ///    [FlatLibraryDao.findBestMatch]). Older than `flatStaleDays` (7 d)
  ///    warns — flats go bad with any dust or optical-train change. A flat
  ///    without an optical-train tag matched against a context that has one
  ///    also warns.
  ///  * **Defect maps**: per camera id; nearest temperature bucket.
  ///
  /// A gain / offset the CONTEXT does not carry ([LightFrameContext.gain] /
  /// [LightFrameContext.offset] null — the lights' capture metadata never
  /// recorded it) is not compared at all: matching proceeds on the remaining
  /// dimensions, the pick's `reasons` name the dimension as UNVERIFIED and its
  /// `warnings` say the master was chosen without it. No substitute value is
  /// invented, so a metadata-less sub can neither silently draw the masters of
  /// a gain-0 library nor spuriously fail every candidate.
  ///
  /// When a shared calibration library is configured ([_remoteLibrary]) and
  /// [includeRemote] is set, ranked remote candidates join the same per-type
  /// ranking, local-first on an exact tuple tie. The chosen master's provenance
  /// rides on the result; [acceptRemoteMaster] downloads and merges it.
  Future<CalibrationMatchSet> match(
    LightFrameContext context, {
    CalibrationMatchTolerances tolerances = CalibrationMatchTolerances.defaults,
    bool includeRemote = true,
  }) async {
    final remote = _remote;
    if (remote != null) {
      // Remote client: the appliance owns the real master library, so the
      // host runs the matcher against its own DB and returns the transparent
      // per-type result.
      final result = await remote.matchCalibrationMasters(context);
      _ensureAuthority();
      return result;
    }
    // Enrich exactly as [listMasters] does. A master flat whose filter lives
    // only in its FITS header has a null `filter` column, so without this it is
    // visible and correctly labelled in the Calibration Library while this
    // matcher reports "No matching master flat for filter X" about the very
    // record on screen — and silently drops flat-field correction.
    final all = await _enrichAll(await _loadAll());
    String? remoteWarning;
    if (includeRemote && _remoteLibrary != null) {
      // Signed out is a NORMAL state, not a failure: no exception, no error log
      // — but it still means the shared library was not consulted, and an empty
      // remote set here must never read as "the hub had nothing to offer".
      if (!await _remoteLibrary.isConfigured()) {
        remoteWarning =
            'Not signed in to a shared calibration hub — shared masters were '
            'not consulted; showing local masters only.';
      } else {
        try {
          final candidates = await _remoteLibrary.queryCandidates(context);
          for (final candidate in candidates) {
            if (_remoteCandidatePasses(candidate, context)) all.add(candidate);
          }
        } on Object catch (e) {
          // Folding remote candidates is strictly additive and best-effort: a
          // hub failure must never degrade local matching, but the operator
          // must see that shared masters were not consulted (offline != 'none
          // exist').
          developer.log(
            'Remote calibration candidates skipped: $e',
            name: 'CalibrationLibraryService',
            level: 900,
          );
          remoteWarning =
              'Shared calibration hub unreachable — shared masters were not '
              'consulted; showing local masters only.';
        }
      }
    }
    final setWarnings = <String>[];
    if (remoteWarning != null) setWarnings.add(remoteWarning);

    final dark = _matchDark(
      all.where((r) => r.type == CalibrationMasterType.dark),
      context,
      tolerances,
    );
    if (dark == null) {
      setWarnings.add(
        'No matching master dark (gain ${context.gain ?? 'unrecorded'}, offset '
        '${context.offset ?? 'unrecorded'}, bin ${context.binX}x${context.binY}'
        ', ${_fmtSecs(context.exposureSeconds)}) — dark subtraction will be '
        'skipped.',
      );
    }

    final bias = _matchBias(
      all.where((r) => r.type == CalibrationMasterType.bias),
      context,
      tolerances,
    );

    final flat = _matchFlat(
      all.where((r) => r.type == CalibrationMasterType.flat),
      context,
      tolerances,
    );
    if (flat == null) {
      final filterPart =
          (context.filter == null || context.filter!.trim().isEmpty)
          ? ''
          : ' for filter ${context.filter!.trim()}';
      setWarnings.add(
        'No matching master flat$filterPart (gain '
        '${context.gain ?? 'unrecorded'}, bin ${context.binX}x${context.binY}) '
        '— flat-field correction will be skipped.',
      );
    }

    final defectMap = _matchDefectMap(
      all.where((r) => r.type == CalibrationMasterType.defectMap),
      context,
    );

    return CalibrationMatchSet(
      context: context,
      dark: dark,
      bias: bias,
      flat: flat,
      defectMap: defectMap,
      warnings: setWarnings,
    );
  }

  // Shared calibration libraries

  /// Download a REMOTE master surfaced by [match] and merge it into the local
  /// library, applying the quality + consent gates and conflict resolution:
  ///
  ///  * refuses a non-shareable license, a defect map, or a flat without an
  ///    optical-train tag (a flat is never reusable across trains);
  ///  * CONFLICT RESOLUTION — when a LOCAL master with the exact same tuple
  ///    already exists, prefers the local copy and does NOT download
  ///    ([RemoteMasterAcceptanceKind.preferredLocal]); otherwise downloads,
  ///    writes the file, and inserts a new artifact row + a provenance-stamped
  ///    `calibration_tags` annotation (keeping both)
  ///    ([RemoteMasterAcceptanceKind.merged]).
  ///
  /// AUTHORITY: only [remote]'s `remoteId` is trusted. Everything the matcher
  /// keys on — gain, offset, exposure, temperature, binning, sensor geometry,
  /// filter, optical train, license, provenance — is re-read from the hub's own
  /// row alongside the bytes and it is THAT record which is gated and filed.
  /// [remote] reaches this method across an untrusted boundary (a REST client
  /// posts a `/match` result back to `/api/calibration-library/accept`), so
  /// filing the caller's copy would let a mutated payload register real master
  /// bytes under a tuple they were never shot at — the matcher would then
  /// silently subtract the wrong master from future lights. A hub that supplies
  /// no authoritative record fails CLOSED (refused) rather than falling back to
  /// the caller's metadata.
  Future<RemoteMasterAcceptance> acceptRemoteMaster(
    CalibrationMasterRecord remote,
  ) async {
    if (!remote.isRemote) {
      throw ArgumentError('acceptRemoteMaster requires a remote record');
    }
    final library = _remoteLibrary;
    if (library == null) {
      throw StateError('no shared calibration library is configured');
    }
    // Cheap pre-gates on the caller's copy, purely to avoid spending a download
    // on an ask that cannot be accepted. Both outcomes are conservative — they
    // file nothing — so acting on untrusted metadata here is safe; the
    // authoritative versions of both gates run again after the download.
    final preRefusal = _acceptRefusal(remote);
    if (preRefusal != null) {
      return RemoteMasterAcceptance.refused(preRefusal);
    }
    final preLocal = await _loadAll();
    final preDuplicate = _exactLocalDuplicate(remote, preLocal);
    if (preDuplicate != null) {
      return RemoteMasterAcceptance.preferredLocal(preDuplicate);
    }

    final dirResolver = _sharedMasterDirResolver;
    if (dirResolver == null) {
      throw StateError('no shared-master download directory is configured');
    }
    final download = await library.downloadMaster(remote);
    final authority = download.master?.toMasterRecord(
      remote.sourceHubKey ?? '',
    );
    if (authority == null) {
      return RemoteMasterAcceptance.refused(
        'The hub did not return an authoritative record for this master, so '
        'the calibration tuple it would be filed under cannot be verified.',
      );
    }
    if (authority.remoteId != remote.remoteId) {
      return RemoteMasterAcceptance.refused(
        'The hub returned master ${authority.remoteId} for a request for '
        '${remote.remoteId}; refusing to file mismatched bytes.',
      );
    }

    // Re-run the consent/reuse gates against the HUB's record, not the
    // caller's: a caller could otherwise dress an un-shareable master (or a
    // train-less flat) in an acceptable-looking payload.
    final refusal = _acceptRefusal(authority);
    if (refusal != null) {
      return RemoteMasterAcceptance.refused(refusal);
    }
    // Conflict resolution: prefer a local exact-tuple master over the download.
    final local = await _loadAll();
    final duplicate = _exactLocalDuplicate(authority, local);
    if (duplicate != null) {
      return RemoteMasterAcceptance.preferredLocal(duplicate);
    }

    final dir = await dirResolver();
    final fileName =
        '${calibrationMasterTypeWireName(authority.type)}_'
        '${authority.remoteId}.fits';
    final destPath = '$dir/$fileName';
    final file = File(destPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(download.bytes, flush: true);

    final newId = await _insertAcceptedMaster(authority, destPath);
    return RemoteMasterAcceptance.merged(newId, destPath);
  }

  /// Publish a LOCAL master to the configured hub under [consent]'s license
  /// (consent-gated: refuses when the consent does not permit sharing). The
  /// trust signals (frame count, sensor dimensions, camera) are taken from the
  /// record; [provenance] supplies the rest (e.g. measured dark current).
  Future<SharedCalibrationMaster> publishMaster(
    CalibrationMasterRecord record, {
    required ContributionConsent consent,
    Provenance provenance = const Provenance(),
  }) async {
    final library = _remoteLibrary;
    if (library == null) {
      throw StateError('no shared calibration library is configured');
    }
    if (!consent.permitsSharing) {
      throw StateError(
        'consent does not permit sharing (license '
        '${consent.license.wireName})',
      );
    }
    if (record.type == CalibrationMasterType.defectMap) {
      throw StateError('defect maps cannot be shared');
    }
    if (record.type == CalibrationMasterType.flat &&
        (record.opticalTrainId == null ||
            record.opticalTrainId!.trim().isEmpty)) {
      throw StateError(
        'a flat can only be shared with an optical-train tag (flats are '
        'never reusable across optical trains)',
      );
    }
    final published = await library.publish(
      record: record,
      consent: consent,
      provenance: provenance,
    );
    // Record the hub master id locally so the master can later be retracted
    // (un-shared) — this is the owner-scoped retract handle the UI surfaces.
    await _tagsDao.upsert(
      record.type,
      record.id,
      publishedRemoteId: published.id,
    );
    return published;
  }

  /// Retract (un-share) a LOCAL master the user previously published to the hub.
  ///
  /// On a remote client the call routes to the appliance over REST (the rig owns
  /// the published row + its retract handle); locally it resolves the hub master
  /// id recorded at publish time, calls the hub's owner-scoped delete, and clears
  /// the local retract handle so the master shows as un-shared again. Throws a
  /// [StateError] when the master was never published or no hub is configured.
  Future<void> retractPublishedMaster(CalibrationMasterRecord record) async {
    final remote = _remote;
    if (remote != null) {
      await remote.retractCalibrationMaster(
        type: calibrationMasterTypeWireName(record.type),
        id: record.id,
      );
      return;
    }
    final library = _remoteLibrary;
    if (library == null) {
      throw StateError('no shared calibration library is configured');
    }
    final remoteId =
        record.publishedRemoteId ??
        (await _tagsDao.getForMaster(
          record.type,
          record.id,
        ))?.publishedRemoteId;
    if (remoteId == null || remoteId.isEmpty) {
      throw StateError('this master has not been published to a hub');
    }
    await library.retract(remoteId);
    await _tagsDao.upsert(record.type, record.id, clearPublishedRemoteId: true);
  }

  // Tagging

  /// Replace the user tags of one master.
  Future<void> setTags(
    CalibrationMasterType type,
    int id,
    List<String> tags,
  ) async {
    final cleaned = [
      for (final t in tags)
        if (t.trim().isNotEmpty) t.trim(),
    ];
    final remote = _remote;
    if (remote != null) {
      await remote.setCalibrationMasterTags(
        type: calibrationMasterTypeWireName(type),
        id: id,
        tags: cleaned,
      );
      return;
    }
    await _tagsDao.upsert(type, id, tags: cleaned);
  }

  /// Replace the notes of one master (null/empty clears them).
  Future<void> setNotes(
    CalibrationMasterType type,
    int id,
    String? notes,
  ) async {
    final cleaned = notes?.trim();
    final remote = _remote;
    if (remote != null) {
      await remote.setCalibrationMasterNotes(
        type: calibrationMasterTypeWireName(type),
        id: id,
        notes: cleaned,
      );
      return;
    }
    if (cleaned == null || cleaned.isEmpty) {
      await _tagsDao.upsert(type, id, clearNotes: true);
    } else {
      await _tagsDao.upsert(type, id, notes: cleaned);
    }
  }

  // Deletion

  /// Delete one master's DB row (plus its `calibration_tags` annotation) and,
  /// when [deleteFile] is set, the on-disk artifact(s). Returns false when no
  /// row with that identity exists.
  Future<bool> deleteMaster(
    CalibrationMasterType type,
    int id, {
    bool deleteFile = false,
  }) async {
    final remote = _remote;
    if (remote != null) {
      // The appliance owns the row + file. A 404 there surfaces as a thrown
      // ServerError (no_calibration_master); the caller reloads either way, so
      // success here means the host accepted the delete.
      await remote.deleteCalibrationMaster(
        type: calibrationMasterTypeWireName(type),
        id: id,
        deleteFile: deleteFile,
      );
      return true;
    }
    var found = false;
    switch (type) {
      case CalibrationMasterType.dark:
      case CalibrationMasterType.bias:
        final entry = await (_db.select(
          _db.darkLibrary,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (entry != null) {
          found = true;
          if (deleteFile) {
            await _deleteFileIfExists(entry.filePath);
            if (entry.masterDarkPath != null) {
              await _deleteFileIfExists(entry.masterDarkPath!);
            }
          }
          await (_db.delete(
            _db.darkLibrary,
          )..where((t) => t.id.equals(id))).go();
        }
      case CalibrationMasterType.flat:
        final entry = await _flatDao.getEntryById(id);
        if (entry != null) {
          found = true;
          if (deleteFile) {
            await _deleteFileIfExists(entry.filePath);
          }
          await _flatDao.deleteEntry(id);
        }
      case CalibrationMasterType.defectMap:
        final entry = await (_db.select(
          _db.defectMaps,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (entry != null) {
          found = true;
          if (deleteFile && entry.filePath != null) {
            await _deleteFileIfExists(entry.filePath!);
          }
          await (_db.delete(
            _db.defectMaps,
          )..where((t) => t.id.equals(id))).go();
        }
    }
    if (found) {
      await _tagsDao.deleteForMaster(type, id);
    }
    return found;
  }

  static double _clampScore(double score) => score.clamp(0.0, 100.0);

  static String _fmtDate(DateTime when) =>
      when.toLocal().toIso8601String().split('T').first;
}

/// Riverpod provider for the [CalibrationLibraryService].
final calibrationLibraryServiceProvider = Provider<CalibrationLibraryService>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  final settings = ref.watch(settingsDaoProvider);
  final service = CalibrationLibraryService(
    db: ref.watch(databaseProvider),
    flatLibraryDao: ref.watch(flatLibraryDaoProvider),
    tagsDao: ref.watch(calibrationTagsDaoProvider),
    ref: ref,
    backend: backend,
    // Fold ranked masters shared on the configured Constellation hub into
    // the local ranking, and download-on-accept. Reuses the same settings-backed
    // hub credentials Pillar C resolves; a no-hub config simply yields no remote
    // candidates.
    remoteLibrary: HubCalibrationLibrary(
      credentialsResolver: () => resolveConstellationCredentials(settings),
    ),
    sharedMasterDirResolver: () async {
      final dir = await resolveSkotiqDataDirectory();
      return p.join(dir.path, 'shared_calibration');
    },
  );
  ref.onDispose(service.retire);
  return service;
});
