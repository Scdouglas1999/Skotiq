part of '../calibration_library_service.dart';

extension _CalibrationLibrarySharing on CalibrationLibraryService {
  /// The reason a remote master is refused outright, or null when it may be
  /// accepted. Defense-in-depth: re-applies the consent + cross-train gates at
  /// accept time, not just at match-folding time.
  String? _acceptRefusal(CalibrationMasterRecord remote) {
    if (remote.type == CalibrationMasterType.defectMap) {
      return 'Defect maps are camera/firmware specific and are not shared.';
    }
    if (remote.license == null || !remote.license!.isShareable) {
      return 'This master is not shared under a reusable license.';
    }
    if (remote.type == CalibrationMasterType.flat &&
        (remote.opticalTrainId == null ||
            remote.opticalTrainId!.trim().isEmpty)) {
      return 'A shared flat without an optical-train tag is never reusable.';
    }
    return null;
  }

  /// The LOCAL master whose tuple exactly matches [remote] (so a download would
  /// be a duplicate), or null when none — the "keep both otherwise" branch.
  CalibrationMasterRecord? _exactLocalDuplicate(
    CalibrationMasterRecord remote,
    List<CalibrationMasterRecord> records,
  ) {
    for (final r in records) {
      if (r.isRemote) continue;
      if (r.type != remote.type) continue;
      if (r.gain != remote.gain ||
          r.offset != remote.offset ||
          r.binX != remote.binX ||
          r.binY != remote.binY) {
        continue;
      }
      if (!_sameOptional(r.cameraId, remote.cameraId)) continue;
      // Sensor dimensions must agree when both sides know them.
      if (r.width != null && remote.width != null && r.width != remote.width) {
        continue;
      }
      if (r.height != null &&
          remote.height != null &&
          r.height != remote.height) {
        continue;
      }
      switch (remote.type) {
        case CalibrationMasterType.dark:
          if (!_sameExposure(r.exposureSeconds, remote.exposureSeconds)) {
            continue;
          }
        case CalibrationMasterType.bias:
          break;
        case CalibrationMasterType.flat:
          if (!_sameOptional(r.filter, remote.filter)) continue;
          if (!_sameOptional(r.opticalTrainId, remote.opticalTrainId)) continue;
        case CalibrationMasterType.defectMap:
          continue;
      }
      return r;
    }
    return null;
  }

  /// Insert a downloaded master into its source table + a provenance-stamped
  /// `calibration_tags` row. Returns the new artifact id.
  Future<int> _insertAcceptedMaster(
    CalibrationMasterRecord remote,
    String destPath,
  ) async {
    final now = _now();
    final int newId;
    switch (remote.type) {
      case CalibrationMasterType.dark:
      case CalibrationMasterType.bias:
        newId = await _db
            .into(_db.darkLibrary)
            .insert(
              DarkLibraryCompanion.insert(
                filePath: destPath,
                exposureTime: remote.exposureSeconds ?? 0,
                frameType: Value(
                  remote.type == CalibrationMasterType.bias ? 'bias' : 'dark',
                ),
                temperature: Value(remote.temperature),
                gain: Value(remote.gain ?? 0),
                offset: Value(remote.offset ?? 0),
                binX: Value(remote.binX),
                binY: Value(remote.binY),
                width: Value(remote.width),
                height: Value(remote.height),
                masterDarkPath: Value(destPath),
                masterFrameCount: Value(remote.frameCount),
                createdAt: Value(now),
              ),
            );
      case CalibrationMasterType.flat:
        newId = await _flatDao.addEntry(
          filePath: destPath,
          filter: remote.filter,
          opticalTrainId: remote.opticalTrainId,
          temperature: remote.temperature,
          gain: remote.gain ?? 0,
          offset: remote.offset ?? 0,
          binX: remote.binX,
          binY: remote.binY,
          width: remote.width,
          height: remote.height,
          masterFrameCount: remote.frameCount ?? 0,
          createdAt: now,
        );
      case CalibrationMasterType.defectMap:
        throw StateError('defect maps cannot be merged');
    }
    final sharedBy =
        remote.sharedBy ??
        remote.provenance?.displayName ??
        remote.provenance?.accountId;
    await _tagsDao.upsert(
      remote.type,
      newId,
      cameraId: remote.cameraId,
      sharedBy: sharedBy,
      sharedAt: now,
      license: remote.license?.wireName,
      provenanceJson: remote.provenance?.toJsonString(),
    );
    return newId;
  }

  /// Whether a REMOTE candidate passes the quality gate for [ctx]. The gate
  /// FAILS CLOSED on the trust dimensions — a candidate is folded only when it
  /// is provably sensor-compatible, never when identity is merely unknown:
  ///  * a shareable license;
  ///  * a camera identity that the context names AND the candidate matches (an
  ///    unknown camera on either side is refused — a foreign sensor's
  ///    dark-current / hot-pixel / amp-glow pattern would silently corrupt
  ///    calibration);
  ///  * sensor dimensions the candidate advertises (a candidate with no recorded
  ///    geometry can never be proven sensor-matched, so it is refused), matching
  ///    the context's own geometry exactly when the context knows it;
  ///  * for a flat, an EXACT optical-train match (never train-less, never
  ///    cross-train). Cross-account flat reuse on a bare train name is additionally
  ///    prevented hub-side: `SharedCalibrationService.query` scopes flats to the
  ///    requesting owner, so a candidate that reaches here is same-owner already.
  bool _remoteCandidatePasses(
    CalibrationMasterRecord r,
    LightFrameContext ctx,
  ) {
    if (r.type == CalibrationMasterType.defectMap) return false;
    if (r.license == null || !r.license!.isShareable) return false;
    // Camera identity fails closed: refuse cross-/unknown-camera remotes.
    final wantCam = ctx.cameraId?.trim();
    if (wantCam == null || wantCam.isEmpty) return false;
    if (r.cameraId == null || r.cameraId!.trim() != wantCam) return false;
    // Sensor dimensions fail closed: a candidate that does not advertise its
    // geometry is refused; when the context knows its own geometry the candidate
    // must match it exactly.
    if (r.width == null || r.height == null) return false;
    final cw = ctx.sensorWidth;
    final ch = ctx.sensorHeight;
    if (cw != null && r.width != cw) return false;
    if (ch != null && r.height != ch) return false;
    if (r.type == CalibrationMasterType.flat) {
      final wantTrain = ctx.opticalTrainId?.trim();
      if (wantTrain == null || wantTrain.isEmpty) return false;
      if (r.opticalTrainId == null || r.opticalTrainId!.trim() != wantTrain) {
        return false;
      }
    }
    return true;
  }

  /// Append the trust-surfacing provenance lines for a REMOTE pick: who shared
  /// it, the supporting frame count / dark-current, and the reuse license, plus
  /// a soft "this is shared, verify it" warning.
  void _applyRemoteProvenance(
    CalibrationMasterRecord best,
    List<String> reasons,
    List<String> warnings,
  ) {
    if (!best.isRemote) return;
    final prov = best.provenance;
    final who = best.sharedBy ?? prov?.displayName ?? 'another member';
    final buffer = StringBuffer('Shared master from $who');
    final fc = best.frameCount ?? prov?.frameCount;
    if (fc != null) buffer.write(' ($fc frames');
    final dc = prov?.darkCurrent;
    if (dc != null) {
      buffer.write(
        '${fc != null ? ', ' : ' ('}dark current '
        '${dc.toStringAsFixed(3)} e-/px/s',
      );
    }
    if (fc != null || dc != null) buffer.write(')');
    if (best.license != null) {
      buffer.write(' — license ${best.license!.wireName}');
    }
    reasons.add(buffer.toString());
    warnings.add(
      'This is a SHARED master you did not capture — review its provenance '
      'before trusting your calibration to it.',
    );
  }
}
