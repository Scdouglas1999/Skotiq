// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../flat_wizard_provider.dart';

/// Settings, filter-list and one-line state operations for
/// [FlatWizardNotifier].
extension FlatWizardSettingsOps on FlatWizardNotifier {
  // Mode management

  void setMode(FlatWizardMode mode) {
    state = state.copyWith(mode: mode);
  }

  void setTwilightMode(TwilightMode mode) {
    state = state.copyWith(twilightMode: mode);
  }

  // Global settings

  void updateGlobalSettings(FlatWizardGlobalSettings settings) {
    _settingsRevision++;
    state = state.copyWith(globalSettings: settings);
    _persistGlobalSettings();
  }

  void setHistogramTarget(double percent) {
    _settingsRevision++;
    state = state.copyWith(
      globalSettings: state.globalSettings.copyWith(
        histogramTarget: percent.clamp(0, 100),
      ),
    );
    _persistGlobalSettings();
  }

  void setTolerance(double percent) {
    _settingsRevision++;
    state = state.copyWith(
      globalSettings: state.globalSettings.copyWith(
        tolerancePercent: percent.clamp(1, 25),
      ),
    );
    _persistGlobalSettings();
  }

  void setFrameCount(int count) {
    _settingsRevision++;
    state = state.copyWith(
      globalSettings: state.globalSettings.copyWith(
        frameCount: count.clamp(1, 999),
      ),
    );
    _persistGlobalSettings();
  }

  void setSavePath(String? path) {
    _settingsRevision++;
    state = state.copyWith(
      globalSettings: state.globalSettings.copyWith(savePath: path),
    );
    _persistGlobalSettings();
  }

  /// Restore the six persisted user-facing global-settings fields so the
  /// operator does not re-pick the flat folder (and re-tune targets) every
  /// launch. Applies the stored values onto the current defaults and no-ops on
  /// a missing/malformed record (falling back to defaults, logged like the
  /// file's other fault paths) or once a run or a user edit already owns the
  /// settings (the revision + [_running] guards). A store failure must never
  /// surface to the UI, so it is swallowed after logging.
  Future<void> _hydrateGlobalSettings() async {
    final revisionAtStart = _settingsRevision;
    try {
      final db = ref.read(databaseProvider);
      final raw = await db.settingsDao.getSetting(
        FlatWizardNotifier._globalSettingsKey,
      );
      if (raw == null || raw.isEmpty) return;
      // A run in flight or an eager user edit owns the live settings — never
      // clobber it with the stale on-disk value.
      if (_running || _settingsRevision != revisionAtStart) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final current = state.globalSettings;
      state = state.copyWith(
        globalSettings: current.copyWith(
          savePath: decoded['savePath'] as String?,
          histogramTarget:
              (decoded['histogramTarget'] as num?)?.toDouble() ??
              current.histogramTarget,
          tolerancePercent:
              (decoded['tolerancePercent'] as num?)?.toDouble() ??
              current.tolerancePercent,
          frameCount:
              (decoded['frameCount'] as num?)?.toInt() ?? current.frameCount,
          createDateSubfolder:
              decoded['createDateSubfolder'] as bool? ??
              current.createDateSubfolder,
          createFilterSubfolders:
              decoded['createFilterSubfolders'] as bool? ??
              current.createFilterSubfolders,
        ),
      );
    } catch (e) {
      developer.log(
        'FlatWizard: could not restore persisted global settings (using '
        'defaults): $e',
        name: 'FlatWizardNotifier',
        level: 900,
        error: e,
      );
    }
  }

  /// Persist the six user-facing global-settings fields so they survive an app
  /// restart. Fire-and-forget: a settings-store failure must NEVER block or
  /// fail the UI, so it is surfaced only to the logs (`developer.log` survives
  /// release, unlike a stripped `debugPrint`), mirroring [_recordFlatHistory]'s
  /// non-fatal fault handling. `savePath` is the ACTIVE backend's path;
  /// [runCapture] re-validates a remote path at start, so a stale last-used
  /// value fails closed rather than writing to the wrong host.
  void _persistGlobalSettings() {
    final s = state.globalSettings;
    final payload = jsonEncode(<String, Object?>{
      'savePath': s.savePath,
      'histogramTarget': s.histogramTarget,
      'tolerancePercent': s.tolerancePercent,
      'frameCount': s.frameCount,
      'createDateSubfolder': s.createDateSubfolder,
      'createFilterSubfolders': s.createFilterSubfolders,
    });
    unawaited(
      ref
          .read(databaseProvider)
          .settingsDao
          .setSetting(FlatWizardNotifier._globalSettingsKey, payload)
          .catchError((Object e) {
            developer.log(
              'FlatWizard: failed to persist global settings: $e',
              name: 'FlatWizardNotifier',
              level: 900,
              error: e,
            );
          }),
    );
  }

  // Filter management

  /// Load filters from connected filter wheel
  Future<void> loadFiltersFromWheel() async {
    // No-op while a capture run holds the busy latch. This rebuilds
    // `filterSettings` from scratch (statuses reset to pending, capturedCount to
    // 0), and the screen re-invokes it on every init (postFrameCallback); doing
    // so mid-run would wipe the live per-filter bookkeeping the truthful final
    // summary is computed from.
    if (_running) return;

    final fwState = ref.read(filterWheelStateProvider);
    if (fwState.filterNames.isEmpty) return;

    final backend = ref.read(backendProvider);
    final db = ref.read(databaseProvider);
    final profileId = ref.read(activeEquipmentProfileProvider)?.id;

    final filterSettings = <FlatFilterSettings>[];
    for (int i = 0; i < fwState.filterNames.length; i++) {
      final filterName = fwState.filterNames[i];

      // Get suggested exposure from history. On a remote client the local
      // `flat_history` table is empty (the master owns it), so derive the
      // suggestion from the host's flat history via `listFlats` — mirroring
      // `getSuggestedExposure`'s last-N-average logic — instead of the
      // always-null local DAO read.
      final double? suggested;
      if (backend is NetworkBackend) {
        suggested = await _remoteSuggestedExposure(
          backend,
          filterName: filterName,
          profileId: profileId,
        );
      } else {
        suggested = await db.flatHistoryDao.getSuggestedExposure(
          filterName: filterName,
          equipmentProfileId: profileId,
        );
      }

      filterSettings.add(
        FlatFilterSettings(
          filterName: filterName,
          filterPosition: i,
          suggestedExposure: suggested,
        ),
      );
    }

    // Point the quick-capture selection at the wheel's PHYSICAL position so a
    // fresh screen shoots the loaded filter, not row 0. `currentFilterIndex` is
    // otherwise only ever written by the run loop; nothing else syncs it to the
    // wheel. Fall back to 0 when the position is unknown or has no matching row.
    // Guaranteed not-running here (guard at the top), so this cannot disturb an
    // active run's progress index.
    var initialFilterIndex = 0;
    final currentPosition = fwState.currentPosition;
    if (currentPosition != null) {
      final match = filterSettings.indexWhere(
        (f) => f.filterPosition == currentPosition,
      );
      if (match >= 0) initialFilterIndex = match;
    }

    state = state.copyWith(
      filterSettings: filterSettings,
      currentFilterIndex: initialFilterIndex,
    );
  }

  /// Average of the last few host flat-history exposures for [filterName],
  /// mirroring `FlatHistoryDao.getSuggestedExposure` (last-N average) but
  /// sourced from the master via `GET /api/calibration/flats`. Returns null
  /// when the host has no history for this filter.
  Future<double?> _remoteSuggestedExposure(
    NetworkBackend backend, {
    required String filterName,
    int? profileId,
  }) async {
    try {
      final entries = await backend.listFlats(
        filter: filterName,
        equipmentProfileId: profileId,
        limit: 5,
      );
      if (entries.isEmpty) return null;
      final sum = entries.fold<double>(0, (s, e) => s + e.exposureDuration);
      return sum / entries.length;
    } catch (e) {
      // A transport/host fault must not block the wizard from loading; the
      // user can still enter exposures manually (same outcome as a null DAO
      // read on the local path). But unlike an empty history, a fault is a
      // diagnosable condition — record it instead of silently conflating the
      // two so a misconfigured/offline host is visible in the logs.
      developer.log(
        'FlatWizard: remote flat-history fetch failed for $filterName: $e',
        name: 'FlatWizardNotifier',
        level: 900,
        error: e,
      );
      debugRemoteFaultSink?.call(e);
      return null;
    }
  }

  /// Toggle filter enabled state.
  ///
  /// No-op while a capture run holds the busy latch: the run captured its
  /// filter list (with stable original indices) at start, so enabling/disabling
  /// a filter mid-run would desynchronize those indices from the live list.
  void toggleFilter(int index, bool enabled) {
    if (_running) return;
    if (index < 0 || index >= state.filterSettings.length) return;

    final updated = [...state.filterSettings];
    updated[index] = updated[index].copyWith(enabled: enabled);
    state = state.copyWith(filterSettings: updated);
  }

  /// Update per-filter settings. No-op while capturing (see [toggleFilter]).
  void updateFilterSettings(int index, FlatFilterSettings settings) {
    if (_running) return;
    if (index < 0 || index >= state.filterSettings.length) return;

    final updated = [...state.filterSettings];
    updated[index] = settings;
    state = state.copyWith(filterSettings: updated);
  }

  /// Auto-order filters for twilight. No-op while capturing (reorder guard).
  void autoOrderForTwilight() {
    if (_running) return;
    if (state.filterSettings.isEmpty) return;

    // Define filter restrictiveness (higher = more restrictive = less light)
    const restrictiveness = {
      'Ha': 100,
      'H-alpha': 100,
      'Halpha': 100,
      'SII': 95,
      'S-II': 95,
      'S2': 95,
      'OIII': 90,
      'O-III': 90,
      'O3': 90,
      'NII': 85,
      'N-II': 85,
      'R': 50,
      'Red': 50,
      'G': 45,
      'Green': 45,
      'B': 40,
      'Blue': 40,
      'L': 10,
      'Lum': 10,
      'Luminance': 10,
      'Clear': 10,
    };

    int getRestrictiveness(String filter) {
      for (final entry in restrictiveness.entries) {
        if (filter.toLowerCase().contains(entry.key.toLowerCase())) {
          return entry.value;
        }
      }
      return 50; // Default middle value
    }

    final sorted = [...state.filterSettings];
    sorted.sort((a, b) {
      final aVal = getRestrictiveness(a.filterName);
      final bVal = getRestrictiveness(b.filterName);

      if (state.twilightMode == TwilightMode.dusk) {
        // Dusk (darkening): most restrictive first
        return bVal.compareTo(aVal);
      } else {
        // Dawn (brightening): least restrictive first
        return aVal.compareTo(bVal);
      }
    });

    state = state.copyWith(filterSettings: sorted);
  }

  // Visualization toggles

  void toggleAduGraph(bool show) {
    state = state.copyWith(showAduGraph: show);
  }

  void toggleFilterCards(bool show) {
    state = state.copyWith(showFilterCards: show);
  }

  /// Reserve startup before the UI awaits a save-location dialog. The capture
  /// run's own latch cannot engage until that dialog returns, so this prevents
  /// a second tab/button from opening another dialog in the meantime.
  bool reserveStartPrompt() {
    if (isBusy) return false;
    _startPromptReserved = true;
    return true;
  }

  void releaseStartPrompt() {
    _startPromptReserved = false;
  }

  void requestCancel() {
    // Cooperative: flip the active run's token. The run's calibration and
    // frame loops poll it and race [FlatCancelToken.whenCancelled], so an
    // in-flight exposure is aborted rather than waited out.
    _cancelToken?.cancel();
    if (_running) {
      state = state.copyWith(statusMessage: 'Cancelling...');
    }
  }

  bool get cancelRequested => _cancelToken?.isCancelled ?? false;

  void clearError() {
    state = state.copyWith(errorMessage: null);
  }

  void clearWarning() {
    state = state.copyWith(warningMessage: null);
  }

  void setStatusMessage(String? message) {
    state = state.copyWith(statusMessage: message);
  }

  void setErrorMessage(String? message) {
    state = state.copyWith(errorMessage: message);
  }

  void setWarningMessage(String? message) {
    state = state.copyWith(warningMessage: message);
  }

  void setCapturing(bool capturing) {
    state = state.copyWith(isCapturing: capturing);
  }

  void setExposing(bool exposing, {DateTime? startTime, double? duration}) {
    state = state.copyWith(
      isExposing: exposing,
      exposureStartTime: startTime,
      currentExposureDuration: duration,
    );
  }

  // ADU history

  void addAduMeasurement(double exposure, double adu) {
    final measurement = AduMeasurement(
      exposure: exposure,
      adu: adu,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(aduHistory: [...state.aduHistory, measurement]);
  }

  void clearAduHistory() {
    state = state.copyWith(aduHistory: []);
  }

  // Image preview

  /// Publish the frame the preview panel should show.
  ///
  /// Typed on purpose. The panel needs the frame's dimensions to render it, so
  /// bare display bytes are unrenderable and get dropped silently: the largest
  /// element on the wizard then reads "No flat captured yet" for an entire run
  /// while frames land on disk. `lastImageData` is `Object?` on the state (it
  /// is runtime-only and never serialised), so the type is enforced here.
  void setLastImage(String? path, CapturedImageResult? imageData) {
    state = state.copyWith(lastImagePath: path, lastImageData: imageData);
  }

  // Filter progress

  /// Internal run-progress update: advances the "current filter" as the run
  /// loop walks its queue. Unguarded on purpose — the run OWNS this while it
  /// holds the busy latch. User-facing selection goes through [selectQuickFilter]
  /// instead, so guarding one does not stall the other.
  void setCurrentFilterIndex(int index) {
    state = state.copyWith(currentFilterIndex: index);
  }

  /// User-facing quick-capture filter selection (the Quick tab dropdown).
  ///
  /// No-op while a capture run holds the busy latch: the run captured its target
  /// filter at start and drives [setCurrentFilterIndex] itself for progress, so
  /// a user change mid-run would repoint the capture. Mirrors [toggleFilter]'s
  /// guard.
  void selectQuickFilter(int index) {
    if (_running) return;
    if (index < 0 || index >= state.filterSettings.length) return;
    state = state.copyWith(currentFilterIndex: index);
  }

  void setCurrentFrameIndex(int index) {
    state = state.copyWith(currentFrameIndex: index);
  }

  void updateFilterStatus(int index, FilterCalibrationStatus status) {
    if (index < 0 || index >= state.filterSettings.length) return;

    final updated = [...state.filterSettings];
    updated[index] = updated[index].copyWith(status: status);
    state = state.copyWith(filterSettings: updated);
  }

  void updateFilterCalibration(int index, double exposure, double adu) {
    if (index < 0 || index >= state.filterSettings.length) return;

    final updated = [...state.filterSettings];
    updated[index] = updated[index].copyWith(
      calibratedExposure: exposure,
      currentAdu: adu,
    );
    state = state.copyWith(filterSettings: updated);
  }

  void incrementFilterCapturedCount(int index) {
    if (index < 0 || index >= state.filterSettings.length) return;

    final updated = [...state.filterSettings];
    updated[index] = updated[index].copyWith(
      capturedCount: updated[index].capturedCount + 1,
    );
    state = state.copyWith(filterSettings: updated);
  }
}
