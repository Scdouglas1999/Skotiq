import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../database/daos/integrated_masters_dao.dart';
import '../database/database.dart';
import '../models/calibration/dark_library_match_tolerances.dart';
import '../models/imaging/integrated_master.dart';
import '../models/imaging/integration_settings.dart';
import '../providers/dark_library_provider.dart';
import 'dark_library_service.dart';
import 'flat_library_service.dart';
import 'logging_service.dart';
import 'post_session_seam.dart';

/// The clause the native side puts in every refusal of an accumulator sidecar
/// whose format this build has retired.
///
/// The seam between the two sides is a plain string, so this phrase is the
/// marker: `masters.rs`'s `describe_sidecar_error` writes it and a test on each
/// side pins it. It is a sentence rather than a code because the same message
/// is what the operator reads.
const String kRetiredMasterSidecarMarker =
    'accumulator format has been retired';

/// The suffix an archived-aside accumulator carries.
const String kSupersededSidecarSuffix = '.v1-superseded';

/// True when [error] is the native side refusing a retired accumulator.
bool isRetiredMasterSidecar(Object error) =>
    '$error'.contains(kRetiredMasterSidecarMarker);

/// What a retired accumulator cost and what replaced it.
///
/// Returned so the caller — and the night's report — can say which master the
/// subs actually went into, rather than silently pointing at a master id that
/// no longer accepts folds.
class MasterRestartNotice {
  /// The master whose accumulator was retired.
  final int retiredMasterId;

  /// The master the night was folded into instead.
  final int newMasterId;

  /// Where the retired accumulator state was moved.
  final String archivedSidecarPath;

  /// The archived calibration log, when there was one.
  final String? archivedCalibrationLogPath;

  /// The native side's own words for why the accumulator was retired.
  final String reason;

  const MasterRestartNotice({
    required this.retiredMasterId,
    required this.newMasterId,
    required this.archivedSidecarPath,
    this.archivedCalibrationLogPath,
    required this.reason,
  });
}

/// Drives the **multi-night accumulating master** workflow on top of the native
/// `api_master_accumulate` (create / add / finalize / info) FFI op.
///
/// The headline post-session feature: keep folding new nights' accepted subs
/// into an existing master over time without re-reading old subs. The resumable
/// accumulator state lives in a `.skmaster` sidecar (the native side owns it);
/// this service owns the *bookkeeping* — the `integrated_masters` row (status
/// `accumulating`, mode `runningWeightedMean`), the per-sub `integrated_master_frames`
/// fold records, and the dedup that prevents a sub being folded twice.
///
/// Idempotency / dedup: [addNight] subtracts the already-folded `image_id`s
/// (from [IntegratedMastersDao.getFoldedImageIds]) from the supplied subs before
/// the native `add`, so re-running an add with overlapping subs never
/// double-counts. This echoes the cross-stream dedup concern in project memory.
class MasterAccumulationService {
  MasterAccumulationService({
    required IntegratedMastersDao mastersDao,
    required DarkLibraryService darkLibrary,
    required FlatLibraryService flatLibrary,
    required PostSessionSeam seam,
    DarkLibraryMatchTolerances darkTolerances =
        DarkLibraryMatchTolerances.defaults,
    LoggingService? logger,
    void Function(MasterRestartNotice notice)? onMasterRestarted,
  }) : _mastersDao = mastersDao,
       _darkLibrary = darkLibrary,
       _flatLibrary = flatLibrary,
       _seam = seam,
       _darkTolerances = darkTolerances,
       _logger = logger,
       _onMasterRestarted = onMasterRestarted;

  final IntegratedMastersDao _mastersDao;
  final DarkLibraryService _darkLibrary;
  final FlatLibraryService _flatLibrary;
  final PostSessionSeam _seam;
  final LoggingService? _logger;
  final void Function(MasterRestartNotice notice)? _onMasterRestarted;

  /// The restart this service last performed, or null when it has performed
  /// none. Read by a caller that needs to re-pin the master under review.
  MasterRestartNotice? get lastRestart => _lastRestart;
  MasterRestartNotice? _lastRestart;

  /// Dark-frame match tolerances, resolved from
  /// [darkLibraryMatchTolerancesProvider] at the provider boundary so this
  /// post-session accumulation matcher agrees with the coverage UI and the live
  /// calibration path, rather than the code defaults.
  final DarkLibraryMatchTolerances _darkTolerances;

  /// Create a new accumulating master for [targetId] / [filter] from a
  /// [referenceSub] (the frozen geometric + photometric anchor).
  ///
  /// Writes the sidecar at [sidecarPath] and inserts the `integrated_masters`
  /// row in status `accumulating`. Returns the new master id.
  Future<int> createMaster({
    required CapturedImage referenceSub,
    required String sidecarPath,
    IntegrationSettings settings = IntegrationSettings.defaults,
    int? targetId,
    String? targetName,
    String? filter,
    double? onlineClipLow = 4.0,
    double? onlineClipHigh = 4.0,
  }) async {
    final result = await _seam.masterAccumulate({
      'op': 'create',
      'referencePath': referenceSub.filePath,
      'sidecarPath': sidecarPath,
      'settings': {
        if (onlineClipLow != null) 'onlineClipLow': onlineClipLow,
        if (onlineClipHigh != null) 'onlineClipHigh': onlineClipHigh,
      },
      if (filter != null && filter.trim().isNotEmpty) 'filter': filter.trim(),
      if (targetName != null && targetName.trim().isNotEmpty)
        'target': targetName.trim(),
    });

    return _mastersDao.insertMaster(
      targetId: targetId,
      name: _masterName(targetName: targetName, filter: filter),
      masterFitsPath: null,
      previewPngPath: null,
      sidecarPath: result.sidecarPath,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.accumulating,
      accumulationMode: AccumulationMode.runningWeightedMean,
      channels: result.channels,
      width: result.width,
      height: result.height,
      frameCount: result.frameCount,
      totalIntegrationSeconds: result.totalIntegrationSec,
      filter: (filter != null && filter.trim().isNotEmpty)
          ? filter.trim()
          : null,
      settingsJson: settings.toJsonString(),
      statsJson: '{}',
    );
  }

  /// Fold a new night's accepted [subs] into the accumulating master [masterId].
  ///
  /// Subs already folded (tracked in `integrated_master_frames`) are skipped.
  /// Calibration is resolved per sub-group from the master's filter + the subs'
  /// shared capture parameters. The master's running totals + fold records are
  /// updated. [label] is recorded in the native fold log (an ISO date / session
  /// id). [biasPath] is the optional master-bias override.
  ///
  /// Returns the [MasterAccumulateResult] from the native add. Throws
  /// [StateError] when the master is missing or has no sidecar, and
  /// [ArgumentError] when [subs] is empty.
  Future<MasterAccumulateResult> addNight({
    required int masterId,
    required List<CapturedImage> subs,
    required String label,
    IntegrationSettings settings = IntegrationSettings.defaults,
    String? biasPath,
    String? runId,
    bool allowRestart = true,
  }) async {
    if (subs.isEmpty) {
      throw ArgumentError.value(subs, 'subs', 'must not be empty');
    }
    final master = await _mastersDao.getById(masterId);
    if (master == null) {
      throw StateError('Integrated master $masterId not found');
    }
    final sidecar = master.sidecarPath;
    if (sidecar == null || sidecar.trim().isEmpty) {
      throw StateError(
        'Master $masterId has no accumulator sidecar; it is not an '
        'accumulating master',
      );
    }
    // A master this service already superseded: its accumulator is on disk
    // under the archive suffix and its own path is empty. Say which file holds
    // the retired state instead of letting the native side report a missing
    // one — and do NOT supersede it a second time, which would leave a trail of
    // empty masters behind one operator pressing the same button twice.
    final archived = File('$sidecar$kSupersededSidecarSuffix');
    if (!_sidecarExists(sidecar) && archived.existsSync()) {
      throw StateError(
        'Master $masterId was superseded: its accumulated state was archived '
        'to ${archived.path} because its $kRetiredMasterSidecarMarker. Add '
        'this night to the newer master for this target instead.',
      );
    }

    // Dedup: drop subs already folded into this master.
    final already = await _mastersDao.getFoldedImageIds(masterId);
    final fresh = subs.where((s) => !already.contains(s.id)).toList();
    if (fresh.isEmpty) {
      // Nothing new — return current totals without touching the sidecar.
      return _seam.masterAccumulate({'op': 'info', 'sidecarPath': sidecar});
    }

    final calibration = await _resolveCalibration(
      subs: fresh,
      filter: master.filter,
      biasPath: biasPath,
      cosmeticCorrection: settings.cosmeticCorrection,
    );

    final MasterAccumulateResult result;
    try {
      result = await _seam.masterAccumulate({
        'op': 'add',
        'sidecarPath': sidecar,
        'lightPaths': fresh.map((s) => s.filePath).toList(),
        'exposuresSec': fresh
            .map((s) => s.exposureDuration)
            .toList(growable: false),
        'label': label,
        'calibration': calibration,
        'settings': settings.toBridgeSettings(),
        // A fold started without a run id is not cancellable, and the native
        // side says so rather than pretending. With one,
        // `api_post_session_cancel` stops it at its next frame and the sidecar
        // is left untouched.
        if (runId != null && runId.isNotEmpty) 'runId': runId,
      });
    } catch (error) {
      if (!allowRestart || !isRetiredMasterSidecar(error)) rethrow;
      // The accumulator this master has been growing was built by a Skotiq
      // whose normalization erased star flux, so it cannot be extended. The
      // night is not lost and neither are the subs: archive the retired state,
      // start a master beside it, and fold tonight into that.
      return _supersedeRetiredMaster(
        retired: master,
        sidecar: sidecar,
        subs: fresh,
        label: label,
        settings: settings,
        biasPath: biasPath,
        runId: runId,
        reason: '$error',
      );
    }

    // Record each freshly-folded sub. The native add path either folds a sub or
    // fails the whole call (it does not partially accept), so on success every
    // `fresh` sub contributed. The native result carries the per-frame
    // integration weight in `lightPaths` order — which is `fresh` order — so we
    // persist each sub's real weight (rather than null) to feed the multi-night
    // growth / best-night intelligence. A weight that came back <= 0 (frame
    // effectively dropped) is stored as null, matching the batch path.
    final weights = result.frameWeights;
    for (var i = 0; i < fresh.length; i++) {
      final w = i < weights.length ? weights[i] : null;
      await _mastersDao.recordFoldedFrame(
        masterId: masterId,
        imageId: fresh[i].id,
        weight: (w != null && w > 0) ? w : null,
        accepted: true,
      );
    }

    await _mastersDao.updateBookkeeping(
      masterId,
      frameCount: result.frameCount,
      totalIntegrationSeconds: result.totalIntegrationSec,
      channels: result.channels,
      width: result.width,
      height: result.height,
    );

    return result;
  }

  /// Retire an accumulator this build can no longer extend and carry the night
  /// into a fresh master beside it.
  ///
  /// The version bump behind this is not a bug in the sidecar: version 1 holds
  /// sums a defective normalization had already erased star flux from, so
  /// extending it would fold good subs into bad data. The native side refuses
  /// it, honestly and permanently — this is the other half, so the refusal does
  /// not cost the operator the night.
  ///
  /// Nothing is deleted. The retired accumulator and its calibration log are
  /// renamed aside with [kSupersededSidecarSuffix], and the retired master's
  /// row is left exactly as it stands, because what it records DID happen. The
  /// new master starts from tonight's first sub and has no fold records, so
  /// every sub of every earlier night is selectable again — they are all still
  /// on disk and re-integrate cleanly.
  Future<MasterAccumulateResult> _supersedeRetiredMaster({
    required IntegratedMaster retired,
    required String sidecar,
    required List<CapturedImage> subs,
    required String label,
    required IntegrationSettings settings,
    String? biasPath,
    String? runId,
    required String reason,
  }) async {
    final archivedSidecar = _archiveAside(sidecar);
    final archivedLog = _archiveAside('$sidecar.calib.json');

    final newSidecar = _freeSidecarPath(sidecar);
    final created = await _seam.masterAccumulate({
      'op': 'create',
      'referencePath': subs.first.filePath,
      'sidecarPath': newSidecar,
      'settings': <String, dynamic>{},
      if (retired.filter != null && retired.filter!.trim().isNotEmpty)
        'filter': retired.filter!.trim(),
    });
    final newMasterId = await _mastersDao.insertMaster(
      targetId: retired.targetId,
      name: retired.name,
      masterFitsPath: null,
      previewPngPath: null,
      sidecarPath: created.sidecarPath,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.accumulating,
      accumulationMode: AccumulationMode.runningWeightedMean,
      channels: created.channels,
      width: created.width,
      height: created.height,
      frameCount: created.frameCount,
      totalIntegrationSeconds: created.totalIntegrationSec,
      filter: retired.filter,
      settingsJson: settings.toJsonString(),
      statsJson: '{}',
    );

    final notice = MasterRestartNotice(
      retiredMasterId: retired.id,
      newMasterId: newMasterId,
      archivedSidecarPath: archivedSidecar ?? sidecar,
      archivedCalibrationLogPath: archivedLog,
      reason: reason,
    );
    _lastRestart = notice;
    _logger?.warning(
      'The accumulating master "${retired.name}" could not take tonight\'s '
      'subs: its $kRetiredMasterSidecarMarker, because it was built by a '
      'Skotiq whose frame normalization erased star flux from every fold. '
      'Its accumulated state was archived to ${notice.archivedSidecarPath} and '
      'a new master (id $newMasterId) was started from tonight, which the '
      'night was folded into. Every original sub is untouched on disk, so the '
      'earlier nights can be re-added to the new master whenever you want '
      'them.',
      source: 'MasterAccumulationService',
      fields: {
        'retiredMasterId': '${retired.id}',
        'newMasterId': '$newMasterId',
        'archivedSidecar': notice.archivedSidecarPath,
        if (archivedLog != null) 'archivedCalibrationLog': archivedLog,
      },
    );
    _onMasterRestarted?.call(notice);

    // `allowRestart: false`: a sidecar this call just created cannot itself be
    // a retired one, and a second restart would mean a loop rather than a fix.
    return addNight(
      masterId: newMasterId,
      subs: subs,
      label: label,
      settings: settings,
      biasPath: biasPath,
      runId: runId,
      allowRestart: false,
    );
  }

  /// Whether the accumulator file is where the row says it is.
  bool _sidecarExists(String sidecar) {
    try {
      return File(sidecar).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  /// Rename [path] aside, returning where it went, or null when there was
  /// nothing there to move.
  ///
  /// A rename rather than a delete: the retired state is the only record of how
  /// those nights were accumulated, and an operator who wants it back should
  /// find it on disk rather than in a support thread.
  String? _archiveAside(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    var destination = '$path$kSupersededSidecarSuffix';
    var n = 2;
    while (File(destination).existsSync()) {
      destination = '$path$kSupersededSidecarSuffix-$n';
      n++;
    }
    try {
      file.renameSync(destination);
      return destination;
    } on FileSystemException catch (error) {
      _logger?.warning(
        'The retired accumulator at $path could not be moved aside, so the '
        'new master was written beside it instead',
        source: 'MasterAccumulationService',
        fields: {'error': '$error'},
      );
      return null;
    }
  }

  /// A sidecar path beside [sidecar] that nothing occupies.
  String _freeSidecarPath(String sidecar) {
    final directory = p.dirname(sidecar);
    final extension = p.extension(sidecar);
    final stem = p.basenameWithoutExtension(sidecar);
    for (var n = 2; ; n++) {
      final candidate = p.join(directory, '$stem-v$n$extension');
      if (!File(candidate).existsSync()) return candidate;
    }
  }

  /// Finalize the accumulating master [masterId] — write its shareable FITS to
  /// [masterFitsPath] (+ optional preview) and stamp the path/status onto the
  /// `integrated_masters` row.
  ///
  /// The status flips to `finalized`, but the sidecar is retained so more nights
  /// can still be added and the master re-finalized.
  Future<MasterAccumulateResult> finalizeMaster({
    required int masterId,
    required String masterFitsPath,
    String? previewPngPath,
  }) async {
    final master = await _mastersDao.getById(masterId);
    if (master == null) {
      throw StateError('Integrated master $masterId not found');
    }
    final sidecar = master.sidecarPath;
    if (sidecar == null || sidecar.trim().isEmpty) {
      throw StateError('Master $masterId has no accumulator sidecar');
    }

    final result = await _seam.masterAccumulate({
      'op': 'finalize',
      'sidecarPath': sidecar,
      'masterFitsPath': masterFitsPath,
      if (previewPngPath != null && previewPngPath.trim().isNotEmpty)
        'previewPngPath': previewPngPath,
    });

    await _mastersDao.updateBookkeeping(
      masterId,
      masterFitsPath: result.masterPath ?? masterFitsPath,
      previewPngPath: result.previewPath,
      status: IntegratedMasterStatus.finalized,
      frameCount: result.frameCount,
      totalIntegrationSeconds: result.totalIntegrationSec,
      channels: result.channels,
      width: result.width,
      height: result.height,
    );

    return result;
  }

  /// Read the live accumulator totals from the sidecar without modifying it.
  Future<MasterAccumulateResult> info(int masterId) async {
    final master = await _mastersDao.getById(masterId);
    if (master == null) {
      throw StateError('Integrated master $masterId not found');
    }
    final sidecar = master.sidecarPath;
    if (sidecar == null || sidecar.trim().isEmpty) {
      throw StateError('Master $masterId has no accumulator sidecar');
    }
    return _seam.masterAccumulate({'op': 'info', 'sidecarPath': sidecar});
  }

  Future<Map<String, dynamic>> _resolveCalibration({
    required List<CapturedImage> subs,
    String? filter,
    String? biasPath,
    required bool cosmeticCorrection,
  }) async {
    final anchor = subs.first;
    final gain = anchor.gain ?? 0;
    final offset = anchor.offset ?? 0;
    final binX = anchor.binX;
    final binY = anchor.binY;
    final temperature = anchor.sensorTemp;
    final matchFilter = (filter != null && filter.trim().isNotEmpty)
        ? filter.trim()
        : anchor.filter;

    final dark = await _darkLibrary.findMatchingDark(
      exposureTime: anchor.exposureDuration,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
      tolerances: _darkTolerances,
    );
    final flat = await _flatLibrary.findBestMatch(
      filter: matchFilter,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
    );

    final darkPath = dark?.masterDarkPath ?? dark?.filePath;
    return {
      if (darkPath != null) 'dark': darkPath,
      if (flat != null) 'flat': flat.filePath,
      if (biasPath != null && biasPath.trim().isNotEmpty) 'bias': biasPath,
      'cosmeticCorrection': cosmeticCorrection,
    };
  }

  String _masterName({String? targetName, String? filter}) {
    final base = (targetName != null && targetName.trim().isNotEmpty)
        ? targetName.trim()
        : 'Master';
    final f = (filter != null && filter.trim().isNotEmpty)
        ? filter.trim()
        : null;
    return f != null ? '$base · $f' : base;
  }
}

/// Provider for the [MasterAccumulationService].
final masterAccumulationServiceProvider = Provider<MasterAccumulationService>((
  ref,
) {
  return MasterAccumulationService(
    mastersDao: ref.watch(integratedMastersDaoProvider),
    darkLibrary: ref.watch(darkLibraryServiceProvider),
    flatLibrary: ref.watch(flatLibraryServiceProvider),
    seam: ref.watch(postSessionSeamProvider),
    darkTolerances: ref.watch(darkLibraryMatchTolerancesProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});
