// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../flat_wizard_provider.dart';

/// The capture lifecycle for [FlatWizardNotifier].
extension FlatWizardRun on FlatWizardNotifier {
  // Capture lifecycle

  /// Run the full flat-capture lifecycle for the current mode: per-filter
  /// calibration, frame capture, FITS save, and history recording.
  ///
  /// This is the single authoritative entry point. The screen only resolves
  /// the save path (dialog) and calls this; all validation, cancellation, and
  /// truthful outcome reporting live here so the UI cannot drift from reality.
  ///
  /// Contract:
  ///   * Rejected (no-op) if a run already holds the busy latch — no double
  ///     start, no overlapping camera ownership.
  ///   * `isCapturing` is set ONLY after validation passes, so a failed
  ///     precondition never flashes the "Capturing" badge.
  ///   * Per-filter state updates use the STABLE original index into
  ///     `filterSettings`, so quick-mode (current filter != row 0) and disabled
  ///     leading filters update the correct rows.
  ///   * Cancellation is cooperative and aborts the in-flight exposure exactly
  ///     once (see [FlatWizardService.exposeAndAwait]); no further frame or
  ///     filter is started afterward.
  ///   * A frame counts as saved ONLY after its FITS write succeeds; a save
  ///     failure is a capture failure. History is recorded ONLY when at least
  ///     one real file landed on disk; a filter is marked complete/partial/
  ///     failed truthfully from the saved count.
  ///   * The final status message is PERSISTED — it is not cleared on exit.
  Future<void> runCapture() async {
    // Busy latch FIRST (synchronous, before any await) so a second start is
    // rejected even while the async validation below is in flight.
    if (_running) {
      developer.log(
        'FlatWizard: runCapture ignored — a run is already active',
        name: 'FlatWizardNotifier',
        level: 900,
      );
      return;
    }
    _running = true;
    final cancelToken = FlatCancelToken();
    _cancelToken = cancelToken;

    try {
      // Snapshot the global settings ONCE. The settings panel stays editable
      // mid-run (as does the tab bar, see runMode below), so reading
      // `state.globalSettings` live inside the per-filter loop let an edit
      // change the frame target, the target ADU and the output layout of the
      // filters still to come — and misrecord in flat history the target the
      // frames were actually shot at.
      final runSettings = state.globalSettings;
      final backend = ref.read(backendProvider);
      final cameraState = ref.read(cameraStateProvider);
      // Build the service inline from the current backend + settings rather
      // than `ref.read(flatWizardServiceProvider)`: that provider `ref.watch`es
      // THIS provider's state, so reading it from our own notifier would form a
      // circular provider dependency.
      final flatService = FlatWizardService.fromSettings(backend, runSettings);
      final db = ref.read(databaseProvider);
      final activeProfile = ref.read(activeEquipmentProfileProvider);
      final profileId = activeProfile?.id;
      final brightnessTracker = ref.read(skyBrightnessTrackerProvider);

      // Validation (before isCapturing is set)
      if (cameraState.connectionState != DeviceConnectionState.connected ||
          cameraState.deviceId == null) {
        setErrorMessage('Camera not connected');
        return;
      }
      final cameraId = cameraState.deviceId!;

      // Global camera/hardware ownership: refuse to start if the camera is
      // already mid-exposure for another operation (imaging/sequence). Prevents
      // two owners driving the same camera into a fault.
      if (cameraState.isExposing) {
        setErrorMessage('Camera is busy with another exposure');
        return;
      }

      var savePath = runSettings.savePath;
      if (savePath == null || savePath.isEmpty) {
        setErrorMessage('No save path set');
        return;
      }
      if (backend is NetworkBackend) {
        try {
          savePath = await validateRemoteFlatOutputDirectory(backend, savePath);
        } catch (error) {
          setErrorMessage(
            'Flat-frame save path is not usable on the imaging host: $error',
          );
          setStatusMessage('Failed — choose a writable host folder.');
          return;
        }
      }

      final queue = _buildFilterQueue();
      if (queue.isEmpty) {
        setErrorMessage('No filters selected');
        return;
      }

      // Snapshot the run's algorithm mode ONCE, right where the filter queue is
      // latched. runCapture otherwise reads `state.mode`/`state.twilightMode`
      // LIVE deep in the per-filter loop (sky-flats rate tracking at the
      // calibrate step and the recorded twilight phase). The tab bar stays
      // intentionally tappable mid-run so the operator can browse, which flips
      // `state.mode` live — without this snapshot, peeking at the Sky Flats tab
      // during a Batch run would silently switch the algorithm for the
      // remaining filters.
      final runMode = state.mode;
      final runTwilightMode = state.twilightMode;

      // Resolve ONE effective capture configuration from the connected camera
      // (host-authoritative on a NetworkBackend) + active profile, and publish
      // it so the UI preview, this capture command, the FITS header, and the DB
      // record all agree. maxAdu drives the target so a 12/14-bit camera does
      // not chase an impossible ADU; gain/offset are `null` (camera default)
      // rather than a stale zero when unset; binning honours the profile and
      // camera capability.
      final config = await ref
          .read(flatCameraConfigProvider.notifier)
          .resolve(
            fallbackBinX: runSettings.binning,
            fallbackBinY: runSettings.binning,
            failIfStale: true,
          );
      if (!config.rangeKnown) {
        setErrorMessage(
          'Could not determine the connected camera\'s ADU range. '
          'Reconnect the camera or refresh its capabilities before starting '
          'automatic flat calibration.',
        );
        setStatusMessage('Failed — camera ADU range is unknown.');
        return;
      }
      final liveCameraAfterResolve = ref.read(cameraStateProvider);
      if (liveCameraAfterResolve.connectionState !=
              DeviceConnectionState.connected ||
          liveCameraAfterResolve.deviceId != cameraId ||
          liveCameraAfterResolve.isExposing) {
        setErrorMessage(
          'Camera changed state while preparing flat capture. Try again once '
          'the camera is connected and idle.',
        );
        setStatusMessage('Failed — camera changed while preparing.');
        return;
      }

      // Committed: from here we are truly capturing
      _prepareFiltersForRun(queue);
      state = state.copyWith(
        isCapturing: true,
        errorMessage: null,
        warningMessage: null,
        statusMessage: 'Initializing...',
        aduHistory: const [],
        currentFrameIndex: 0,
      );
      final historyGain = config.gain ?? cameraState.gain ?? 0;

      // Base save path with optional date subfolder.
      var baseSavePath = savePath;
      if (runSettings.createDateSubfolder) {
        baseSavePath = p.join(baseSavePath, _fmtDate(DateTime.now()));
      }
      final createOutputLocally = backend is! NetworkBackend;
      await prepareFlatOutputDirectory(
        baseSavePath,
        createLocally: createOutputLocally,
      );

      var cancelled = false;
      // Set when a timeout / uncertain-camera outcome forces a fail-safe STOP of
      // the whole run (distinct from a user cancel). Carries the actionable
      // message surfaced to the operator.
      String? haltError;

      for (final queued in queue) {
        if (cancelToken.isCancelled) {
          cancelled = true;
          break;
        }

        // Fast-fail on a mid-run camera disconnect instead of waiting out a
        // full exposure timeout on the next frame. The exposure's own timeout
        // remains the ultimate guard for a disconnect that lands mid-exposure.
        final liveCamera = ref.read(cameraStateProvider);
        if (liveCamera.connectionState != DeviceConnectionState.connected ||
            liveCamera.deviceId == null) {
          haltError = 'Camera disconnected — run stopped.';
          break;
        }

        final idx = queued.originalIndex;
        final filterSetting = queued.settings;
        setCurrentFilterIndex(idx);
        updateFilterStatus(idx, FilterCalibrationStatus.calibrating);
        setStatusMessage('Calibrating ${filterSetting.filterName}...');

        final moveError = await moveFilterWheelAndWait(
          filterSetting.filterPosition,
          cancelToken,
        );
        if (cancelToken.isCancelled) {
          updateFilterStatus(idx, FilterCalibrationStatus.skipped);
          cancelled = true;
          break;
        }
        if (moveError != null) {
          // Fail-safe: an uncertain filter position taints every remaining
          // filter, so stop the whole run rather than capture the wrong flat.
          updateFilterStatus(idx, FilterCalibrationStatus.failed);
          haltError = '${filterSetting.filterName}: $moveError — run stopped.';
          break;
        }

        // Calibrate exposure
        // Target ADU is an absolute value against the DETECTED full scale, so a
        // 12/14-bit camera targets e.g. 50% of 4095/16383 — never an impossible
        // 32768.
        final targetAdu = FlatExposureCalculator.histogramPercentToAdu(
          filterSetting.histogramTargetOverride ?? runSettings.histogramTarget,
          maxAdu: config.maxAdu,
        ).toDouble();
        final tolerance =
            filterSetting.toleranceOverride ?? runSettings.tolerancePercent;
        final minExp =
            filterSetting.minExposureOverride ?? runSettings.minExposure;
        final maxExp =
            filterSetting.maxExposureOverride ?? runSettings.maxExposure;

        final FlatResult calibration;
        if (runMode == FlatWizardMode.skyFlats) {
          calibration = await flatService.calibrateFilterWithRateTracking(
            deviceId: cameraId,
            filter: filterSetting.filterName,
            gain: config.gain,
            offset: config.offset,
            targetAdu: targetAdu,
            tolerance: tolerance,
            minExposure: minExp,
            maxExposure: maxExp,
            binX: config.binX,
            binY: config.binY,
            brightnessTracker: brightnessTracker,
            historicalExposure: filterSetting.suggestedExposure,
            cancelToken: cancelToken,
            onProgress: (iteration, exposure, adu, status) {
              addAduMeasurement(exposure, adu);
              updateFilterCalibration(idx, exposure, adu);
              setStatusMessage(
                '${filterSetting.filterName}: $status '
                '(${exposure.toStringAsFixed(2)}s, ADU: ${adu.toStringAsFixed(0)})',
              );
            },
          );
        } else {
          calibration = await flatService.calibrateFilter(
            deviceId: cameraId,
            filter: filterSetting.filterName,
            gain: config.gain,
            offset: config.offset,
            targetAdu: targetAdu,
            tolerance: tolerance,
            minExposure: minExp,
            maxExposure: maxExp,
            binX: config.binX,
            binY: config.binY,
            cancelToken: cancelToken,
            onProgress: (iteration, exposure, adu) {
              addAduMeasurement(exposure, adu);
              updateFilterCalibration(idx, exposure, adu);
              setStatusMessage(
                '${filterSetting.filterName}: Iteration $iteration '
                '(${exposure.toStringAsFixed(2)}s, ADU: ${adu.toStringAsFixed(0)})',
              );
            },
          );
        }

        if (calibration.cancelled) {
          // Calibration never completed for this filter — it is skipped, not
          // failed.
          updateFilterStatus(idx, FilterCalibrationStatus.skipped);
          cancelled = true;
          break;
        }
        if (calibration.haltRun) {
          // Fail-safe: a calibration exposure timed out or the camera's idle
          // state is uncertain — stop the WHOLE run rather than risk overlapping
          // exposures. Surface an actionable error.
          updateFilterStatus(idx, FilterCalibrationStatus.failed);
          haltError = calibration.cameraStateUnknown
              ? '${filterSetting.filterName}: '
                    '${calibration.errorMessage ?? "camera state unknown"} — '
                    'run stopped; check the camera.'
              : '${filterSetting.filterName}: '
                    '${calibration.errorMessage ?? "exposure timed out"} — '
                    'run stopped.';
          break;
        }
        if (!calibration.success) {
          updateFilterStatus(idx, FilterCalibrationStatus.failed);
          setWarningMessage(
            '${filterSetting.filterName}: '
            '${calibration.errorMessage ?? "Calibration failed"}',
          );
          continue; // move on to the next filter
        }

        updateFilterCalibration(idx, calibration.exposure, calibration.adu);
        updateFilterStatus(idx, FilterCalibrationStatus.capturing);

        // Frame capture
        var filterSavePath = baseSavePath;
        if (runSettings.createFilterSubfolders) {
          filterSavePath = p.join(
            baseSavePath,
            _sanitizeComponent(filterSetting.filterName),
          );
          await prepareFlatOutputDirectory(
            filterSavePath,
            createLocally: createOutputLocally,
          );
        }

        final frameCount =
            filterSetting.frameCountOverride ?? runSettings.frameCount;
        var savedCount = 0;
        var frameCancelled = false;
        var frameHalted = false;

        for (int frameNum = 1; frameNum <= frameCount; frameNum++) {
          if (cancelToken.isCancelled) {
            frameCancelled = true;
            break;
          }

          // Fast-fail if the camera dropped between frames rather than waiting
          // out this frame's exposure timeout.
          final frameCamera = ref.read(cameraStateProvider);
          if (frameCamera.connectionState != DeviceConnectionState.connected ||
              frameCamera.deviceId == null) {
            frameHalted = true;
            haltError = 'Camera disconnected — run stopped.';
            break;
          }

          setCurrentFrameIndex(frameNum);
          setStatusMessage(
            '${filterSetting.filterName}: Capturing frame $frameNum/$frameCount',
          );
          setExposing(
            true,
            startTime: DateTime.now(),
            duration: calibration.exposure,
          );

          // Authoritative capture: waits for the real completion event (no
          // fixed delay), aborts the hardware on cancel/timeout, and uses the
          // one resolved effective config (gain/offset/binning).
          final capture = await flatService.exposeAndAwait(
            deviceId: cameraId,
            exposureTime: calibration.exposure,
            gain: config.gain,
            offset: config.offset,
            binX: config.binX,
            binY: config.binY,
            cancelToken: cancelToken,
          );
          setExposing(false);

          if (capture.isCancelled) {
            // A cancelled exposure is never saved or counted.
            frameCancelled = true;
            break;
          }

          if (capture.isTimedOut) {
            // Fail-safe: the exposure timed out. Never read a stale image and
            // never start the next frame while the prior may still be active —
            // stop the run. When the camera could not be confirmed idle the
            // operator must check the hardware.
            frameHalted = true;
            haltError = capture.cameraQuiescent
                ? '${filterSetting.filterName} frame $frameNum timed out — '
                      'run stopped.'
                : '${filterSetting.filterName} frame $frameNum timed out and '
                      'the camera could not be confirmed idle — run stopped; '
                      'check the camera.';
            break;
          }

          if (capture.outcome != FlatFrameOutcome.completed) {
            // Per-frame error is surfaced, not swallowed. It is NOT counted as
            // a saved frame.
            setWarningMessage(
              '${filterSetting.filterName} frame $frameNum failed: '
              '${capture.error ?? "capture failed"}',
            );
            continue;
          }

          // Save the frame. A save failure IS a capture failure: the frame is
          // surfaced as failed and NOT counted.
          final captureTime = DateTime.now();
          final filename =
              '${_sanitizeComponent('Flat_${filterSetting.filterName}_'
              '${_fmtStamp(captureTime)}_$frameNum')}.fits';
          final filePath = p.join(filterSavePath, filename);
          try {
            await backend.saveFitsFromLastCapture(
              deviceId: cameraId,
              filePath: filePath,
              headerData: FitsWriteHeader(
                frameType: 'FLAT',
                filter: filterSetting.filterName,
                exposureTime: calibration.exposure,
                captureTimestamp: captureTime.toUtc().toIso8601String(),
                gain: config.gain,
                offset: config.offset,
                binX: config.binX,
                binY: config.binY,
              ),
            );
          } catch (e) {
            setWarningMessage(
              '${filterSetting.filterName} frame $frameNum save failed: $e',
            );
            continue;
          }

          // Only NOW is the frame real on disk. Update counters + preview.
          savedCount++;
          incrementFilterCapturedCount(idx);
          final image = capture.image;
          if (image != null) {
            setLastImage(filePath, image);
            addAduMeasurement(calibration.exposure, image.stats.mean);
          }
        }

        // Truthful per-filter status from the real saved count
        final FilterCalibrationStatus finalStatus;
        if (savedCount == 0) {
          finalStatus = frameCancelled
              ? FilterCalibrationStatus.skipped
              : FilterCalibrationStatus.failed;
        } else if (savedCount < frameCount) {
          finalStatus = FilterCalibrationStatus.partial;
        } else {
          finalStatus = FilterCalibrationStatus.complete;
        }
        updateFilterStatus(idx, finalStatus);

        // Record history ONLY when at least one real file landed on disk. Any
        // frames written before a halt are real and still learned from.
        if (savedCount > 0) {
          await _recordFlatHistory(
            backend: backend,
            db: db,
            profileId: profileId,
            filterName: filterSetting.filterName,
            exposure: calibration.exposure,
            adu: calibration.adu,
            gain: historyGain,
            brightnessTracker: brightnessTracker,
            runMode: runMode,
            runTwilightMode: runTwilightMode,
            histogramTarget: runSettings.histogramTarget,
          );
        }

        // Fail-safe stop: a timed-out / uncertain-camera frame stops the whole
        // run, never just this filter.
        if (frameHalted) break;

        if (frameCancelled || cancelToken.isCancelled) {
          cancelled = true;
          break;
        }
      }

      if (haltError != null) {
        // A fail-safe stop: surface the actionable message and persist it as
        // both the status and an error so the operator is not left guessing.
        setStatusMessage(haltError);
        setErrorMessage(haltError);
      } else {
        _setFinalStatus(queue: queue, cancelled: cancelled);
      }
    } catch (e, st) {
      developer.log(
        'FlatWizard: capture run failed: $e',
        name: 'FlatWizardNotifier',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      setErrorMessage('Capture failed: $e');
      setStatusMessage('Capture failed.');
    } finally {
      // Persist the final status message (do NOT clear it) — the run's outcome
      // stays visible until a deliberate next start or reset. Only the
      // transient capture/exposing flags are cleared and the latch released.
      state = state.copyWith(isCapturing: false, isExposing: false);
      _running = false;
    }
  }

  /// Build the ordered list of filters to capture, each paired with its STABLE
  /// index into `filterSettings`.
  ///
  /// Quick mode captures ONLY the currently-selected filter, carrying its real
  /// row index (not 0) so its status/count updates hit the right row. Batch/sky
  /// modes capture every enabled filter, each carrying its true row index so a
  /// disabled leading filter does not shift the mapping.
  List<_QueuedFilter> _buildFilterQueue() {
    final filters = state.filterSettings;
    if (state.mode == FlatWizardMode.quick) {
      final idx = state.currentFilterIndex;
      if (filters.isNotEmpty && idx >= 0 && idx < filters.length) {
        return [_QueuedFilter(idx, filters[idx])];
      }
      return const [];
    }
    final queue = <_QueuedFilter>[];
    for (var i = 0; i < filters.length; i++) {
      if (filters[i].enabled) queue.add(_QueuedFilter(i, filters[i]));
    }
    return queue;
  }

  /// Reset the queued filters to a clean per-run state (pending, zero saved
  /// count) so the final summary and progress reflect THIS run, not a prior
  /// one. Filters not in the queue keep their state.
  void _prepareFiltersForRun(List<_QueuedFilter> queue) {
    final updated = [...state.filterSettings];
    for (final q in queue) {
      if (q.originalIndex < 0 || q.originalIndex >= updated.length) continue;
      updated[q.originalIndex] = updated[q.originalIndex].copyWith(
        status: FilterCalibrationStatus.pending,
        capturedCount: 0,
      );
    }
    state = state.copyWith(filterSettings: updated);
  }

  /// Compute and persist a truthful final status from the LIVE filter rows
  /// (never an immutable snapshot captured at loop start).
  void _setFinalStatus({
    required List<_QueuedFilter> queue,
    required bool cancelled,
  }) {
    var complete = 0;
    var partial = 0;
    var failed = 0;
    var framesSaved = 0;
    for (final q in queue) {
      if (q.originalIndex < 0 ||
          q.originalIndex >= state.filterSettings.length) {
        continue;
      }
      final f = state.filterSettings[q.originalIndex];
      switch (f.status) {
        case FilterCalibrationStatus.complete:
          complete++;
          break;
        case FilterCalibrationStatus.partial:
          partial++;
          break;
        case FilterCalibrationStatus.failed:
          failed++;
          break;
        default:
          break;
      }
      framesSaved += f.capturedCount;
    }

    if (cancelled) {
      setStatusMessage(
        'Cancelled — saved $framesSaved frame${framesSaved == 1 ? '' : 's'}; '
        '$complete complete, $partial partial.',
      );
      return;
    }
    if (complete == queue.length && partial == 0 && failed == 0) {
      setStatusMessage(
        'Complete — ${queue.length} filter${queue.length == 1 ? '' : 's'}, '
        '$framesSaved frame${framesSaved == 1 ? '' : 's'} saved.',
      );
      return;
    }
    if (complete == 0 && partial == 0) {
      setStatusMessage('Failed — no frames saved.');
      setErrorMessage('Flat capture failed — no frames were saved.');
      return;
    }
    setStatusMessage(
      'Finished with issues — $complete complete, $partial partial, '
      '$failed failed; $framesSaved frame${framesSaved == 1 ? '' : 's'} saved.',
    );
  }

  /// Move the filter wheel to [position] and wait for it to actually settle.
  ///
  /// Returns `null` on success (or when there is no wheel, or the DEVICE — not
  /// the cached provider — confirms it is already at [position]). Returns an
  /// actionable error string when the move itself FAILS (the
  /// driver threw) — the caller must then STOP the run rather than capture a
  /// flat through an unknown filter.
  ///
  /// Settle is STATE-DRIVEN, not a blind fixed delay: after a short floor (to
  /// bridge the gap before a just-started move is reflected in the polled wheel
  /// state), it waits until the wheel reports it is no longer moving AND has
  /// reached [position]. A backend that does not report a position is not
  /// considered settled: after [maxWait] the move fails closed so a flat is
  /// never captured through an unknown filter. A cooperative cancel
  /// short-circuits the wait promptly.
  Future<String?> moveFilterWheelAndWait(
    int position,
    FlatCancelToken cancelToken, {
    Duration maxWait = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 100),
    Duration settleFloor = const Duration(milliseconds: 150),
  }) async {
    final fwState = ref.read(filterWheelStateProvider);
    if (fwState.connectionState != DeviceConnectionState.connected ||
        fwState.deviceId == null) {
      return null; // no wheel to drive
    }
    final deviceBackend = ref.read(deviceBackendProvider);
    final fwNotifier = ref.read(filterWheelStateProvider.notifier);

    // Confirm where the wheel REALLY is before deciding the move can be
    // skipped. `filterWheelSetPosition` publishes no position event, so a wheel
    // driven by anything that does not poll afterwards — the headless
    // /filterwheel/position endpoint the web dashboard uses, or a settle that
    // timed out — leaves this provider stale. Trusting the cached position here
    // would skip the move and shoot the flat through whichever filter is
    // actually in the path. An unreadable status is not treated as "already
    // there": fall through and command the move.
    var settledHere = false;
    try {
      final status = await deviceBackend.getFilterWheelStatus(
        fwState.deviceId!,
      );
      // A negative position is the drivers' "in transit" encoding, same as
      // DeviceService treats it.
      final isMoving = status.moving || status.position < 0;
      fwNotifier.updatePosition(status.position);
      fwNotifier.setMoving(isMoving);
      settledHere = !isMoving && status.position == position;
    } catch (e) {
      developer.log(
        'FlatWizard: could not confirm the wheel position before moving to '
        '$position ($e) — commanding the move rather than assuming',
        name: 'FlatWizardNotifier',
        level: 900,
      );
    }
    if (settledHere) {
      return null; // confirmed already at the target
    }

    try {
      await deviceBackend.filterWheelSetPosition(fwState.deviceId!, position);
    } catch (e) {
      developer.log(
        'FlatWizard: filter wheel move to $position failed: $e',
        name: 'FlatWizardNotifier',
        level: 1000,
        error: e,
      );
      return 'filter wheel failed to move ($e)';
    }

    // Floor: give the driver/state a moment to register that the move started
    // so an async wheel that reports `isMoving` a beat late is not mistaken for
    // already-settled (which would expose mid-move). Skipped on cancel.
    if (!cancelToken.isCancelled) {
      await Future<void>.delayed(settleFloor);
    }

    // Wait for the wheel to report it has stopped moving AND reached the target.
    //
    // The wheel is re-read from the BACKEND each pass and the result pushed
    // back into the provider, the same way `DeviceService._verify
    // FilterWheelPosition` does. Polling the provider alone would never see a
    // change (nothing else fetches status here), so every move would "fail"
    // on timeout, and a stale provider would let the next run take the
    // already-in-position shortcut against a wheel that never moved.
    var waited = Duration.zero;
    while (waited < maxWait) {
      if (cancelToken.isCancelled) return null; // caller handles the cancel

      final live = ref.read(filterWheelStateProvider);
      if (live.connectionState != DeviceConnectionState.connected ||
          live.deviceId != fwState.deviceId) {
        return 'filter wheel disconnected before reaching position $position';
      }

      try {
        final status = await deviceBackend.getFilterWheelStatus(
          fwState.deviceId!,
        );
        // A negative position is the drivers' "in transit" encoding, same as
        // DeviceService treats it.
        final isMoving = status.moving || status.position < 0;
        fwNotifier.updatePosition(status.position);
        fwNotifier.setMoving(isMoving);
        if (!isMoving && status.position == position) return null; // settled
      } catch (e) {
        return 'filter wheel status read failed while settling ($e)';
      }

      await Future<void>.delayed(pollInterval);
      waited += pollInterval;
    }
    // A named-filter exposure is unsafe while position is unverified. Stop
    // rather than silently photographing through whichever filter happens to
    // be in the optical path.
    developer.log(
      'FlatWizard: filter wheel settle not confirmed within '
      '${maxWait.inSeconds}s (stopping fail-safe)',
      name: 'FlatWizardNotifier',
      level: 900,
    );
    return 'filter wheel did not confirm position $position within '
        '${maxWait.inSeconds}s';
  }

  /// Record a completed filter's calibration to flat history. Preserves the
  /// remote-vs-local routing exactly: on a [NetworkBackend] the record is
  /// posted to the master (so its library learns from the remote session);
  /// otherwise it is written to the local DAO. Never throws — a history-write
  /// failure must not fail the capture (the frames are already on disk).
  Future<void> _recordFlatHistory({
    required dynamic backend,
    required dynamic db,
    required int? profileId,
    required String filterName,
    required double exposure,
    required double adu,
    required int gain,
    required SkyBrightnessTracker brightnessTracker,
    required FlatWizardMode runMode,
    required TwilightMode runTwilightMode,
    required double histogramTarget,
  }) async {
    try {
      // Use the run's snapshotted mode/twilight, not `state.mode`/
      // `state.twilightMode`: browsing to another tab mid-run flips those live
      // and would misrecord the sky-flats rate / twilight phase for the
      // remaining filters.
      final skyAduRate = runMode == FlatWizardMode.skyFlats
          ? brightnessTracker.calculateRate()
          : null;
      final twilightPhase = runMode == FlatWizardMode.skyFlats
          ? (runTwilightMode == TwilightMode.dawn ? 'dawn' : 'dusk')
          : null;
      if (backend is NetworkBackend) {
        await backend.recordFlat(
          filter: filterName,
          exposureDuration: exposure,
          adu: adu.toInt(),
          histogramTarget: histogramTarget,
          gain: gain,
          skyAduRate: skyAduRate,
          twilightPhase: twilightPhase,
          equipmentProfileId: profileId,
        );
      } else {
        await db.flatHistoryDao.recordCalibration(
          filterName: filterName,
          exposureTime: exposure,
          histogramTarget: histogramTarget,
          actualAdu: adu.toInt(),
          equipmentProfileId: profileId,
          skyAduRate: skyAduRate,
          twilightPhase: twilightPhase,
        );
      }
    } catch (e, st) {
      // A history-write failure must NOT fail the capture (the frames are
      // already on disk), but it must not vanish either: `debugPrint` is
      // stripped in release, so a persistently-failing library write would be
      // invisible on the appliance. Log at warning level AND surface a
      // non-fatal warning so the operator knows the flat LIBRARY did not learn
      // this exposure (their frames are still saved).
      developer.log(
        'FlatWizard: failed to record calibration to flat history for '
        '$filterName: $e',
        name: 'FlatWizardNotifier',
        level: 900,
        error: e,
        stackTrace: st,
      );
      setWarningMessage(
        '$filterName: frames saved, but the flat library did not record this '
        'calibration ($e).',
      );
    }
  }
}
