part of '../device_service.dart';

extension _DeviceServiceAutofocusControls on DeviceService {
  /// Run autofocus routine
  ///
  /// When [useSettingsDefaults] is true (the default), persisted autofocus
  /// settings supply every field. When false, the explicit panel parameters
  /// override only exposure, step geometry, metric, and binning; persisted
  /// advanced settings (curve fit, retries, crops, settling, backlash, guide
  /// pause, and per-filter behavior) still apply when available.
  ///
  /// If `afDisableGuidingDuringAf` is enabled in settings, guiding is
  /// paused before the AF run and resumed afterwards.
  Future<AutofocusResult> _runAutofocus({
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    bool useSettingsDefaults = true,
  }) async {
    if (_isAutofocusRunning) {
      throw Exception(
        'Autofocus is already running. Wait for it to complete before starting another.',
      );
    }
    if (_isFocuserBacklashCalibrationRunning) {
      throw StateError(
        'A focuser backlash calibration is running. It drives the same camera '
        'and focuser, so autofocus cannot start until it finishes.',
      );
    }
    _isAutofocusRunning = true;
    _autofocusCancelRequested = false;
    _ref.read(sessionStateProvider.notifier).setAutofocusing(true);

    try {
      if (_isFocuserMoveRunning || _ref.read(focuserStateProvider).isMoving) {
        throw StateError(
          'Cannot start autofocus while the focuser is already moving.',
        );
      }
      final focuserDeviceId = await _getFocuserDeviceId();
      if (focuserDeviceId == null || focuserDeviceId.isEmpty) {
        throw Exception('No focuser connected');
      }

      // Use the connected camera's device ID
      final cameraDeviceId = await _getCameraDeviceId();
      if (cameraDeviceId == null || cameraDeviceId.isEmpty) {
        throw Exception('No camera connected');
      }

      // Resolve effective AF parameters from settings or explicit values
      final appSettings = _ref.read(appSettingsProvider).valueOrNull;

      final double effectiveExposureTime;
      final int effectiveStepSize;
      final int effectiveStepsOut;
      final String effectiveMethod;
      final int effectiveBinning;
      final int? effectiveGain;
      final int? effectiveOffset;
      final String effectiveCurveFitting;
      final int effectiveNumberOfAttempts;
      final int effectiveExposuresPerPoint;
      final double effectiveRSquaredThreshold;
      final double effectiveOuterCropRatio;
      final double effectiveInnerCropRatio;
      final int effectiveUseBrightestNStars;
      final int effectiveFocuserSettleTimeMs;
      final String effectiveBacklashCompMethod;
      final int effectiveBacklashIn;
      final int effectiveBacklashOut;
      final bool disableGuidingDuringAf;
      final filterWheelBeforeAutofocus = _ref.read(filterWheelStateProvider);
      final originalFilterPosition = filterWheelBeforeAutofocus.currentPosition;
      final originalFilterName = filterWheelBeforeAutofocus.currentFilterName;
      final perFilterSettings = appSettings == null
          ? const <String, FilterAutofocusConfig>{}
          : AutofocusSettings.parseFilterSettingsJson(
              appSettings.afFilterSettingsJson,
            );
      final activeFilterSettings = originalFilterName == null
          ? null
          : perFilterSettings[originalFilterName];
      final perFilterAfName = activeFilterSettings?.afFilterName?.trim();
      final defaultAfName = appSettings?.afAutofocusFilterName.trim() ?? '';
      final String? autofocusFilterName = perFilterAfName?.isNotEmpty == true
          ? perFilterAfName
          : (defaultAfName.isEmpty ? null : defaultAfName);

      if (useSettingsDefaults && appSettings == null) {
        // Settings not yet loaded from DB — don't silently fall back to hardcoded
        // defaults because the user's persisted configuration would be ignored.
        throw Exception(
          'Cannot run autofocus with settings defaults: AppSettings not yet loaded. '
          'Wait for the app to finish initializing before running autofocus.',
        );
      }

      if (useSettingsDefaults && appSettings != null) {
        effectiveExposureTime =
            activeFilterSettings?.afExposureTime ?? appSettings.afExposureTime;
        effectiveStepSize = appSettings.afStepSize;
        effectiveStepsOut = appSettings.afInitialOffsetSteps;
        effectiveMethod = appSettings.afMethod;
        effectiveBinning =
            activeFilterSettings?.binning ?? appSettings.afBinning;
        effectiveGain = activeFilterSettings?.gain;
        effectiveOffset = activeFilterSettings?.offset;
        effectiveCurveFitting = appSettings.afCurveFitting;
        effectiveNumberOfAttempts = appSettings.afNumberOfAttempts;
        effectiveExposuresPerPoint = appSettings.afExposuresPerPoint;
        effectiveRSquaredThreshold = appSettings.afRSquaredThreshold;
        effectiveOuterCropRatio = appSettings.afOuterCropRatio;
        effectiveInnerCropRatio = appSettings.afInnerCropRatio;
        effectiveUseBrightestNStars = appSettings.afUseBrightestNStars;
        effectiveFocuserSettleTimeMs = appSettings.afFocuserSettleTimeMs;
        effectiveBacklashCompMethod = appSettings.afBacklashCompMethod;
        effectiveBacklashIn = appSettings.afBacklashIn;
        effectiveBacklashOut = appSettings.afBacklashOut;
        disableGuidingDuringAf = appSettings.afDisableGuidingDuringAf;
      } else {
        effectiveExposureTime = exposureTime;
        effectiveStepSize = stepSize;
        effectiveStepsOut = stepsOut;
        effectiveMethod = method;
        effectiveBinning = binning;
        effectiveGain = activeFilterSettings?.gain;
        effectiveOffset = activeFilterSettings?.offset;
        if (appSettings != null) {
          effectiveCurveFitting = appSettings.afCurveFitting;
          effectiveNumberOfAttempts = appSettings.afNumberOfAttempts;
          effectiveExposuresPerPoint = appSettings.afExposuresPerPoint;
          effectiveRSquaredThreshold = appSettings.afRSquaredThreshold;
          effectiveOuterCropRatio = appSettings.afOuterCropRatio;
          effectiveInnerCropRatio = appSettings.afInnerCropRatio;
          effectiveUseBrightestNStars = appSettings.afUseBrightestNStars;
          effectiveFocuserSettleTimeMs = appSettings.afFocuserSettleTimeMs;
          effectiveBacklashCompMethod = appSettings.afBacklashCompMethod;
          effectiveBacklashIn = appSettings.afBacklashIn;
          effectiveBacklashOut = appSettings.afBacklashOut;
          disableGuidingDuringAf = appSettings.afDisableGuidingDuringAf;
        } else {
          effectiveCurveFitting = 'Hyperbolic';
          effectiveNumberOfAttempts = 1;
          effectiveExposuresPerPoint = 1;
          effectiveRSquaredThreshold = 0.7;
          effectiveOuterCropRatio = 1.0;
          effectiveInnerCropRatio = 0.0;
          effectiveUseBrightestNStars = 0;
          effectiveFocuserSettleTimeMs = 500;
          effectiveBacklashCompMethod = 'Overshoot';
          effectiveBacklashIn = 350;
          effectiveBacklashOut = 0;
          disableGuidingDuringAf = false;
        }
      }

      // Read for THIS focuser's id rather than through a provider keyed on
      // "the connected focuser": the run is about to drive `focuserDeviceId`,
      // and a figure measured on any other drive train says nothing about it.
      // Native applies it only when `effectiveBacklashIn` is 0 — a figure the
      // operator typed outranks a measured one.
      final measuredCalibration = await _ref
          .read(settingsDaoProvider)
          .getFocuserBacklashCalibration(focuserDeviceId);
      final measuredBacklashIn =
          measuredCalibration != null && measuredCalibration.measurable
          ? measuredCalibration.steps
          : null;

      final validationError = _validateAutofocusInputs(
        exposureTime: effectiveExposureTime,
        stepSize: effectiveStepSize,
        stepsOut: effectiveStepsOut,
        binning: effectiveBinning,
        numberOfAttempts: effectiveNumberOfAttempts,
        exposuresPerPoint: effectiveExposuresPerPoint,
        rSquaredThreshold: effectiveRSquaredThreshold,
        outerCropRatio: effectiveOuterCropRatio,
        innerCropRatio: effectiveInnerCropRatio,
        useBrightestNStars: effectiveUseBrightestNStars,
        focuserSettleTimeMs: effectiveFocuserSettleTimeMs,
        backlashIn: effectiveBacklashIn,
        backlashOut: effectiveBacklashOut,
        gain: effectiveGain,
        offset: effectiveOffset,
      );
      if (validationError != null) {
        throw ArgumentError('Invalid autofocus settings: $validationError');
      }

      final focuserNotifier = _ref.read(focuserStateProvider.notifier);
      final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
      final overlayNotifier = _ref.read(autofocusOverlayProvider.notifier);

      focuserNotifier.setMoving(true);
      final operationId = operationsNotifier.startOperation(
        type: OperationType.autofocus,
        description: 'Running autofocus ($effectiveMethod)',
        currentStep: 'Initializing...',
        canCancel: true,
      );
      overlayNotifier.onAutofocusStarted();

      var wasGuiding = false;
      var guidingWasPaused = false;
      var filterWasSwitched = false;
      try {
        // Pause guiding before any configured AF-filter switch. Switching
        // filters may also apply a focuser offset, which is part of the AF run
        // and must not happen while a guider the user asked us to pause is
        // still issuing corrections.
        final guiderState = _ref.read(guiderStateProvider);
        wasGuiding = disableGuidingDuringAf && guiderState.isGuiding;
        if (wasGuiding) {
          try {
            final loggingService = _ref.read(loggingServiceProvider);
            loggingService.info(
              'Pausing guiding for autofocus run',
              source: 'DeviceService',
            );
            await stopGuiding();
            guidingWasPaused = true;
          } catch (e) {
            final loggingService = _ref.read(loggingServiceProvider);
            loggingService.error(
              'Cannot run autofocus because guiding could not be paused: $e',
              source: 'DeviceService',
            );
            throw StateError(
              'Autofocus is configured to pause guiding, but guiding could '
              'not be stopped: $e',
            );
          }
        }

        final requestedFilterName = autofocusFilterName;
        if (requestedFilterName != null &&
            requestedFilterName != originalFilterName) {
          if (filterWheelBeforeAutofocus.connectionState !=
                  DeviceConnectionState.connected ||
              filterWheelBeforeAutofocus.deviceId == null ||
              filterWheelBeforeAutofocus.deviceId!.isEmpty) {
            throw StateError(
              'Autofocus is configured to use filter "$requestedFilterName", '
              'but no filter wheel is connected.',
            );
          }
          if (originalFilterPosition == null) {
            throw StateError(
              'Cannot switch to autofocus filter "$requestedFilterName": '
              'the filter wheel does not report its current position, so the '
              'original filter could not be restored safely.',
            );
          }
          final targetPosition = filterWheelBeforeAutofocus.filterNames.indexOf(
            requestedFilterName,
          );
          if (targetPosition < 0) {
            throw StateError(
              'Configured autofocus filter "$requestedFilterName" is not '
              'present in the connected wheel.',
            );
          }
          // From the moment the switch command is sent, restoration is
          // required even if verification or focus-offset application fails:
          // the wheel may already have reached the AF slot before that error.
          filterWasSwitched = true;
          await _setFilterWheelPosition(
            targetPosition,
            requireFocusOffset: true,
            allowDuringAutofocus: true,
          );
        }

        // Predictive-AF consultation (wire-up). Before running the real
        // sweep, ask the persisted per-filter model what it would predict for the
        // current temperature/filter. We log the decision and capture the
        // predicted position so that — once the sweep converges — we can feed the
        // model the prediction-vs-actual error for drift tracking. We never let
        // the prediction REPLACE the Dart sweep here: this path is the explicit
        // full-sweep request (manual focus tab / Dart-driven AF), so the user
        // asked for a real measurement. The prediction is advisory + training
        // input only.
        final predictiveContext = await _consultPredictiveAf(
          method: effectiveMethod,
        );

        if (_autofocusCancelRequested) {
          throw const AutofocusCancelledException();
        }

        final currentFocuser = _ref.read(focuserStateProvider);
        final currentCamera = _ref.read(cameraStateProvider);
        if (currentFocuser.connectionState != DeviceConnectionState.connected ||
            currentFocuser.deviceId != focuserDeviceId ||
            currentCamera.connectionState != DeviceConnectionState.connected ||
            currentCamera.deviceId != cameraDeviceId) {
          throw StateError(
            'Camera or focuser connection changed before autofocus started.',
          );
        }

        AutofocusResult? result;
        Object? runError;
        StackTrace? runStackTrace;
        try {
          result = await _backend.autofocusStart(
            deviceId: focuserDeviceId,
            cameraId: cameraDeviceId,
            exposureTime: effectiveExposureTime,
            stepSize: effectiveStepSize,
            stepsOut: effectiveStepsOut,
            method: effectiveMethod,
            binning: effectiveBinning,
            gain: effectiveGain,
            offset: effectiveOffset,
            curveFitting: effectiveCurveFitting,
            numberOfAttempts: effectiveNumberOfAttempts,
            exposuresPerPoint: effectiveExposuresPerPoint,
            rSquaredThreshold: effectiveRSquaredThreshold,
            outerCropRatio: effectiveOuterCropRatio,
            innerCropRatio: effectiveInnerCropRatio,
            useBrightestNStars: effectiveUseBrightestNStars,
            focuserSettleTimeMs: effectiveFocuserSettleTimeMs,
            backlashCompMethod: effectiveBacklashCompMethod,
            backlashIn: effectiveBacklashIn,
            backlashOut: effectiveBacklashOut,
            measuredBacklashIn: measuredBacklashIn,
          );
        } catch (error, stackTrace) {
          runError = error;
          runStackTrace = stackTrace;
        }

        if (filterWasSwitched) {
          try {
            await _setFilterWheelPosition(
              originalFilterPosition!,
              requireFocusOffset: true,
              allowDuringAutofocus: true,
            );
            filterWasSwitched = false;
          } catch (restoreError, restoreStackTrace) {
            final message = runError == null
                ? 'Autofocus completed, but restoring the original filter '
                      '"${originalFilterName ?? originalFilterPosition}" failed: '
                      '$restoreError'
                : 'Autofocus failed ($runError), and restoring the original '
                      'filter "${originalFilterName ?? originalFilterPosition}" '
                      'also failed: $restoreError';
            Error.throwWithStackTrace(StateError(message), restoreStackTrace);
          }
        }
        if (runError != null) {
          Error.throwWithStackTrace(runError, runStackTrace!);
        }
        if (_autofocusCancelRequested) {
          throw const AutofocusCancelledException();
        }
        final completedResult = result!;

        _ref.read(autofocusResultProvider.notifier).state = completedResult;
        overlayNotifier.onAutofocusCompleted(completedResult);
        _ref
            .read(focuserBacklashOfferSessionProvider.notifier)
            .noteAutofocusOutcome(focuserId: focuserDeviceId);

        // Smart notification for autofocus completion
        final hfrText = completedResult.bestHfr.toStringAsFixed(2);
        _ref
            .read(smartNotificationServiceProvider)
            .showSuccessIfNotOnScreens(
              message: 'Autofocus complete (HFR: $hfrText)',
              relevantScreens: [
                AppScreen.imaging,
                AppScreen.equipment,
                AppScreen.sequencer,
              ],
              title: 'Autofocus',
            );

        // Feed the persisted predictive-AF model (wire-up): record this
        // converged outcome as a training sample and, if we made a prediction
        // before the sweep, record the prediction-vs-actual error for drift
        // tracking. Failures here are logged but never abort the AF run — the
        // user already has their focus result.
        await _recordPredictiveAfOutcome(
          context: predictiveContext,
          result: completedResult,
        );

        return completedResult;
      } catch (e) {
        if (filterWasSwitched && originalFilterPosition != null) {
          try {
            await _setFilterWheelPosition(
              originalFilterPosition,
              requireFocusOffset: true,
              allowDuringAutofocus: true,
            );
          } catch (restoreError, restoreStackTrace) {
            overlayNotifier.onAutofocusFailed(
              'Autofocus failed ($e), and restoring the original filter also '
              'failed: $restoreError',
            );
            Error.throwWithStackTrace(
              StateError(
                'Autofocus failed ($e), and restoring the original filter '
                '"${originalFilterName ?? originalFilterPosition}" also '
                'failed: $restoreError',
              ),
              restoreStackTrace,
            );
          }
        }
        if (_autofocusCancelRequested || _isAutofocusCancellation(e)) {
          overlayNotifier.onAutofocusCancelled();
          throw const AutofocusCancelledException();
        }
        overlayNotifier.onAutofocusFailed('$e');
        _ref
            .read(focuserBacklashOfferSessionProvider.notifier)
            .noteAutofocusOutcome(
              focuserId: focuserDeviceId,
              failureMessage: '$e',
            );
        rethrow;
      } finally {
        focuserNotifier.setMoving(false);
        operationsNotifier.completeOperation(
          OperationType.autofocus,
          operationId: operationId,
        );

        // Resume guiding if it was paused
        if (guidingWasPaused) {
          try {
            final loggingService = _ref.read(loggingServiceProvider);
            loggingService.info(
              'Resuming guiding after autofocus run',
              source: 'DeviceService',
            );
            await startGuiding();
          } catch (e) {
            final loggingService = _ref.read(loggingServiceProvider);
            loggingService.warning(
              'Failed to resume guiding after autofocus: $e',
              source: 'DeviceService',
            );
          }
        }
      }
    } finally {
      _isAutofocusRunning = false;
      _autofocusCancelRequested = false;
      _ref.read(sessionStateProvider.notifier).setAutofocusing(false);
    }
  }

  String? _validateAutofocusInputs({
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    required int binning,
    required int numberOfAttempts,
    required int exposuresPerPoint,
    required double rSquaredThreshold,
    required double outerCropRatio,
    required double innerCropRatio,
    required int useBrightestNStars,
    required int focuserSettleTimeMs,
    required int backlashIn,
    required int backlashOut,
    required int? gain,
    required int? offset,
  }) {
    if (!exposureTime.isFinite || exposureTime < 0.1 || exposureTime > 300) {
      return 'exposure time must be between 0.1 and 300 seconds';
    }
    if (stepSize < 1 || stepSize > 10000) {
      return 'step size must be between 1 and 10000';
    }
    if (stepsOut < 1 || stepsOut > 50) {
      return 'initial offset steps must be between 1 and 50';
    }
    if (binning < 1 || binning > 4) {
      return 'binning must be between 1 and 4';
    }
    if (numberOfAttempts < 1 || numberOfAttempts > 10) {
      return 'number of attempts must be between 1 and 10';
    }
    if (exposuresPerPoint < 1 || exposuresPerPoint > 20) {
      return 'exposures per point must be between 1 and 20';
    }
    if (!rSquaredThreshold.isFinite ||
        rSquaredThreshold < 0 ||
        rSquaredThreshold > 1) {
      return 'R² threshold must be between 0 and 1';
    }
    if (!outerCropRatio.isFinite ||
        !innerCropRatio.isFinite ||
        outerCropRatio <= 0 ||
        outerCropRatio > 1 ||
        innerCropRatio < 0 ||
        innerCropRatio >= outerCropRatio) {
      return 'crop ratios must satisfy 0 ≤ inner < outer ≤ 1';
    }
    if (useBrightestNStars < 0 || useBrightestNStars > 500) {
      return 'brightest-star count must be between 0 and 500';
    }
    if (focuserSettleTimeMs < 0 || focuserSettleTimeMs > 10000) {
      return 'focuser settle time must be between 0 and 10000 ms';
    }
    if (backlashIn < 0 ||
        backlashIn > 10000 ||
        backlashOut < 0 ||
        backlashOut > 10000) {
      return 'backlash values must be between 0 and 10000';
    }
    if ((gain != null && gain < 0) || (offset != null && offset < 0)) {
      return 'gain and offset overrides cannot be negative';
    }
    return null;
  }

  Future<void> _cancelAutofocus() async {
    if (!_isAutofocusRunning || _autofocusCancelRequested) return;
    _autofocusCancelRequested = true;
    _ref
        .read(autofocusOverlayProvider.notifier)
        .onAutofocusCancellationRequested();
    try {
      await _backend.autofocusCancel();
    } catch (_) {
      // A failed cancellation means the run may still own the hardware. Clear
      // the request flag so the UI returns to Running and the operator can
      // retry; the owning autofocus Future remains authoritative.
      _autofocusCancelRequested = false;
      _ref.read(autofocusOverlayProvider.notifier).onAutofocusCancelFailed();
      rethrow;
    }
  }

  bool _isAutofocusCancellation(Object error) {
    if (error is AutofocusCancelledException) return true;
    final text = error.toString().toLowerCase();
    return text.contains('cancelled') || text.contains('canceled');
  }

  /// Resolve the temperature to associate with a predictive-AF sample/decision.
  /// Prefers the temperature the AF backend captured during the sweep (most
  /// accurate, taken at measurement time); otherwise falls back to the
  /// focuser's currently-reported temperature. Returns `null` when neither is
  /// available — the predictive model is temperature-keyed, so we must not
  /// fabricate a reading.
  double? _resolvePredictiveAfTemperature(double? backendTemperature) {
    if (backendTemperature != null) {
      return backendTemperature;
    }
    return _ref.read(focuserStateProvider).temperature;
  }

  /// Consult the persisted predictive-AF model before a real sweep. This is
  /// advisory: we record the decision (for logging + later drift tracking) but
  /// always proceed with the requested full sweep. Returns the context needed
  /// to feed [recordPredictionVsActual] after the sweep, or `null` when the
  /// model cannot be consulted (no filter, no temperature, etc.).
  Future<_PredictiveAfContext?> _consultPredictiveAf({
    required String method,
  }) async {
    final temperature = _resolvePredictiveAfTemperature(null);
    final filterName = _ref.read(filterWheelStateProvider).currentFilterName;
    final profileId = _activeProfile?.id;

    // Without a filter name or a temperature, the model is not keyed/usable.
    // We still want to TRAIN on the outcome (recordAutofocusOutcome handles a
    // missing filter via a sentinel), but we can only meaningfully PREDICT
    // when both are present.
    if (filterName == null || temperature == null) {
      return _PredictiveAfContext(
        profileId: profileId,
        filterName: filterName,
        predictedPosition: null,
      );
    }

    final service = _ref.read(predictiveAfServiceProvider);
    try {
      final decision = await service.evaluateForFilter(
        equipmentProfileId: profileId,
        filterName: filterName,
        temperatureCelsius: temperature,
      );
      final logger = _ref.read(loggingServiceProvider);
      logger.info(
        'Predictive-AF pre-sweep decision for "$filterName" '
        '($method, ${temperature.toStringAsFixed(2)}C): '
        '${decision.runtimeType} '
        '(predicted=${decision.targetPosition}, '
        'confidence=${decision.confidence?.toStringAsFixed(3) ?? "n/a"})',
        source: 'DeviceService',
      );
      // Surface the consultation for the focus UI.
      _ref
          .read(lastPredictiveAfStatusProvider.notifier)
          .state = PredictiveAfStatus(
        at: DateTime.now(),
        filterName: filterName,
        decision: decision,
      );
      return _PredictiveAfContext(
        profileId: profileId,
        filterName: filterName,
        predictedPosition: decision.targetPosition,
      );
    } catch (e) {
      // Advisory-only: a model read failure must not block the real sweep.
      _ref
          .read(loggingServiceProvider)
          .warning(
            'Predictive-AF consultation failed (continuing with real sweep): $e',
            source: 'DeviceService',
          );
      return _PredictiveAfContext(
        profileId: profileId,
        filterName: filterName,
        predictedPosition: null,
      );
    }
  }

  /// Record a converged autofocus outcome into the persisted predictive-AF
  /// model, and (when a pre-sweep prediction exists) record the
  /// prediction-vs-actual error so drift detection can surface re-train
  /// prompts. Never throws into the AF run.
  Future<void> _recordPredictiveAfOutcome({
    required _PredictiveAfContext? context,
    required AutofocusResult result,
  }) async {
    if (context == null) {
      return;
    }
    final temperature = _resolvePredictiveAfTemperature(result.temperature);
    final logger = _ref.read(loggingServiceProvider);

    if (context.filterName == null) {
      logger.info(
        'Predictive-AF: skipping training (no active filter to key the '
        'model). Position=${result.bestPosition}, HFR='
        '${result.bestHfr.toStringAsFixed(2)}.',
        source: 'DeviceService',
      );
      return;
    }
    if (temperature == null) {
      logger.info(
        'Predictive-AF: skipping training for "${context.filterName}" — no '
        'temperature available (focuser reports none). The model is '
        'temperature-keyed; refusing to fabricate a reading.',
        source: 'DeviceService',
      );
      return;
    }

    final service = _ref.read(predictiveAfServiceProvider);
    try {
      await service.recordAutofocusOutcome(
        equipmentProfileId: context.profileId,
        filterName: context.filterName!,
        temperatureCelsius: temperature,
        focusPosition: result.bestPosition,
        hfr: result.bestHfr,
      );
      logger.info(
        'Predictive-AF: recorded outcome for "${context.filterName}" '
        '(pos=${result.bestPosition}, HFR=${result.bestHfr.toStringAsFixed(2)}, '
        '${temperature.toStringAsFixed(2)}C).',
        source: 'DeviceService',
      );

      // Complete the UI status with the converged position so the card can
      // show prediction-vs-actual error.
      final lastStatus = _ref.read(lastPredictiveAfStatusProvider);
      if (lastStatus != null &&
          lastStatus.filterName == context.filterName &&
          lastStatus.actualPosition == null) {
        _ref.read(lastPredictiveAfStatusProvider.notifier).state = lastStatus
            .withActual(result.bestPosition);
      }

      final predicted = context.predictedPosition;
      if (predicted != null) {
        final status = await service.recordPredictionVsActual(
          equipmentProfileId: context.profileId,
          filterName: context.filterName!,
          predictedPosition: predicted,
          actualPosition: result.bestPosition,
        );
        logger.info(
          'Predictive-AF: drift status for "${context.filterName}" = '
          '${status.runtimeType} (predicted=$predicted, '
          'actual=${result.bestPosition}).',
          source: 'DeviceService',
        );
      }
    } catch (e) {
      logger.warning(
        'Predictive-AF: failed to record outcome for "${context.filterName}": $e',
        source: 'DeviceService',
      );
    }
  }
}

/// Carries predictive-AF state across the real autofocus sweep so the
/// pre-sweep prediction can be reconciled with the converged result.
class _PredictiveAfContext {
  final int? profileId;
  final String? filterName;
  final int? predictedPosition;

  const _PredictiveAfContext({
    required this.profileId,
    required this.filterName,
    required this.predictedPosition,
  });
}
