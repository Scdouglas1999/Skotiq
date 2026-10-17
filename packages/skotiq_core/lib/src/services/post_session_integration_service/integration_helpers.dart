part of '../post_session_integration_service.dart';

extension _PostSessionIntegrationHelpers on PostSessionIntegrationService {
  /// Persist the master row + per-sub fold records, returning the new master id.
  Future<int> _persist({
    required int? targetId,
    required String? targetName,
    required String? filter,
    required IntegrationSettings settings,
    required IntegrateSessionResult result,
    required List<CapturedImage> subs,
    required List<String> calibrationWarnings,
  }) async {
    final name = _masterName(targetName: targetName, filter: filter);
    final masterId = await _mastersDao.insertMaster(
      targetId: targetId,
      name: name,
      masterFitsPath: result.masterFitsPath,
      previewPngPath: result.previewPath,
      sidecarPath: null,
      rejectionMapPath: result.rejectionMapPath,
      rejectionMapPreviewPath: result.rejectionMapPreviewPath,
      coverageMapPath: result.coverageMapPath,
      coverageMapPreviewPath: result.coverageMapPreviewPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: result.channels,
      width: result.width,
      height: result.height,
      frameCount: result.framesIntegrated,
      totalIntegrationSeconds: result.totalIntegrationSec,
      filter: filter,
      settingsJson: settings.toJsonString(),
      statsJson: _statsJson(result, calibrationWarnings),
    );

    // Fold-record each sub, keyed by file path so the per-frame native stats map
    // back to the captured-image rows for dedup + the cull UI.
    final byPath = {for (final s in subs) s.filePath: s};
    for (final record in result.perFrameStats) {
      final sub = byPath[record.path];
      if (sub == null) continue;
      await _mastersDao.recordFoldedFrame(
        masterId: masterId,
        imageId: sub.id,
        weight: record.weight > 0 ? record.weight : null,
        alignmentResidualPx: record.rmsResidualPx,
        accepted: record.accepted,
        rejectionReason: record.reason,
        // v42 per-sub science metrics from the native FrameQuality the
        // integration already measured — the Night Doctor reads these.
        snr: record.snr,
        fwhm: record.fwhm,
        eccentricity: record.eccentricity,
      );
    }

    return masterId;
  }

  /// Resolve calibration masters for one filter group from the subs' shared
  /// capture parameters (gain / offset / exposure / temperature / binning /
  /// filter).
  ///
  /// The group's first sub anchors the match parameters; in practice a filter
  /// group from one session shares gain/binning. A dark match requires the
  /// library to hold a compatible master dark, and a flat match requires a
  /// registered master flat for the filter — both return null when absent
  /// (calibration is then skipped for that master type, never faked).
  ///
  /// The anchor's gain, offset and sensor temperature are all nullable columns:
  /// a camera or driver that never reported one leaves it empty. Each is passed
  /// through AS NULL rather than substituted, so the matcher compares the
  /// dimensions the frames actually carry and reports the rest as unverified —
  /// its warnings ride out on [ResolvedCalibration.warnings] into the outcome
  /// and into `integrated_masters.stats_json`, where the dawn autopilot and the
  /// morning report read the same account. Comparing an unrecorded gain against
  /// 0 would instead quietly pick whatever a gain-0 library holds.
  ///
  /// Selection routes through [CalibrationLibraryService.match] so its scored
  /// picks and operator-facing warnings reach the outcome and the morning
  /// report — the one calibration answer, not a second unwarned one.
  Future<ResolvedCalibration> _resolveCalibration({
    required List<CapturedImage> subs,
    String? biasPath,
    required bool cosmeticCorrection,
  }) async {
    final anchor = subs.first;

    final matchSet = await _calibrationLibrary.match(
      LightFrameContext(
        gain: anchor.gain,
        offset: anchor.offset,
        exposureSeconds: anchor.exposureDuration,
        temperature: anchor.sensorTemp,
        filter: anchor.filter,
        binX: anchor.binX,
        binY: anchor.binY,
      ),
      // The automated post-session pipeline can only apply a master that is
      // already on local disk: a REMOTE candidate's `filePath` is null until
      // it is downloaded, and pulling a shared master is a consent-gated,
      // explicit user action (`acceptRemoteMaster`), never a silent
      // auto-download. Folding remote candidates here would let a remote pick
      // with a null path win the ranking and then silently disable dark/flat
      // calibration (its path resolves to null). So match LOCAL-only.
      includeRemote: false,
    );
    final explicitBias = (biasPath != null && biasPath.trim().isNotEmpty)
        ? biasPath
        : null;
    return ResolvedCalibration(
      darkPath: matchSet.dark?.record.filePath,
      flatPath: matchSet.flat?.record.filePath,
      // An explicit bias override wins; otherwise only auto-fill the bias
      // when no dark matched (a matched dark already carries the bias
      // signal — supplying both would double-subtract the pedestal).
      biasPath:
          explicitBias ??
          (matchSet.dark == null ? matchSet.bias?.record.filePath : null),
      cosmeticCorrection: cosmeticCorrection,
      warnings: matchSet.allWarnings,
    );
  }

  Map<String, List<CapturedImage>> _groupByFilter(List<CapturedImage> subs) {
    final out = <String, List<CapturedImage>>{};
    for (final sub in subs) {
      final bucket = _filterBucket(sub.filter);
      out.putIfAbsent(bucket, () => <CapturedImage>[]).add(sub);
    }
    return out;
  }

  String _filterBucket(String? filter) {
    if (filter == null) return PostSessionIntegrationService.noFilterBucket;
    final trimmed = filter.trim();
    return trimmed.isEmpty
        ? PostSessionIntegrationService.noFilterBucket
        : trimmed;
  }

  /// Pick the alignment reference: highest qualityScore, tie-broken by lowest
  /// HFR then most-recent capture. Returns null (⇒ native "auto") when no sub
  /// carries a usable metric, letting the engine choose by composite quality.
  String? _chooseReferencePath(List<CapturedImage> subs) {
    CapturedImage? best;
    for (final s in subs) {
      if (best == null || _isBetterReference(s, best)) {
        best = s;
      }
    }
    // Only hand the native side an explicit reference when we have a graded
    // basis for it; otherwise defer to the engine's composite-quality auto pick.
    if (best == null || (best.qualityScore == null && best.hfr == null)) {
      return null;
    }
    return best.filePath;
  }

  bool _isBetterReference(CapturedImage candidate, CapturedImage current) {
    final cQ = candidate.qualityScore;
    final curQ = current.qualityScore;
    if (cQ != null || curQ != null) {
      if (cQ == null) return false;
      if (curQ == null) return true;
      if (cQ != curQ) return cQ > curQ;
    }
    final cH = candidate.hfr;
    final curH = current.hfr;
    if (cH != null || curH != null) {
      if (cH == null) return false;
      if (curH == null) return true;
      if (cH != curH) return cH < curH;
    }
    return candidate.capturedAt.isAfter(current.capturedAt);
  }

  String _masterName({String? targetName, String? filter}) {
    final base = (targetName != null && targetName.trim().isNotEmpty)
        ? targetName.trim()
        : 'Master';
    if (filter != null && filter.trim().isNotEmpty) {
      return '$base · ${filter.trim()}';
    }
    return base;
  }

  /// The `integrated_masters.stats_json` payload.
  ///
  /// It carries the native applied-masters report verbatim alongside the frame
  /// counts, because the report is otherwise only in the master's FITS header
  /// and in a native result that does not survive the call. The dawn autopilot
  /// reads it back from this column, so a job re-queued after a crash states
  /// the same calibration account the first attempt would have.
  String _statsJson(
    IntegrateSessionResult result,
    List<String> calibrationWarnings,
  ) {
    return jsonEncode({
      'framesIntegrated': result.framesIntegrated,
      'framesRejected': result.framesRejected,
      'rmsResidual': result.rmsResidual,
      'totalIntegrationSec': result.totalIntegrationSec,
      if (result.calibration != null) 'calibration': result.calibration,
      if (calibrationWarnings.isNotEmpty)
        'calibrationWarnings': calibrationWarnings,
    });
  }
}
