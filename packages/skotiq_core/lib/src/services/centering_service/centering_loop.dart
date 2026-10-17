part of '../centering_service.dart';

extension _CenteringLoop on CenteringService {
  Future<void> _stopOwnedHardware() async {
    if (_captureInFlight) {
      _ownedImagingService?.cancelExposure();
    }

    if (_slewInFlight) {
      await _ownedDeviceService?.abortMountSlew();
    }
  }

  String? _validateRequest({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    required CenteringConfig config,
  }) {
    if (!targetRa.isFinite || targetRa < 0 || targetRa > 24) {
      return 'Target RA must be between 0 and 24 hours';
    }
    if (!targetDec.isFinite || targetDec < -90 || targetDec > 90) {
      return 'Target declination must be between -90° and +90°';
    }
    if (config.maxIterations < 1) {
      return 'Centering requires at least one iteration';
    }
    if (!config.toleranceArcsec.isFinite || config.toleranceArcsec <= 0) {
      return 'Centering tolerance must be greater than zero';
    }
    if (!config.exposureTime.isFinite || config.exposureTime <= 0) {
      return 'Centering exposure time must be greater than zero';
    }
    if (config.binning < 1) {
      return 'Centering binning must be at least 1';
    }
    if (config.gain != null && config.gain! < 0) {
      return 'Centering gain cannot be negative';
    }
    if (config.offset != null && config.offset! < 0) {
      return 'Centering offset cannot be negative';
    }
    if (config.overallTimeout <= Duration.zero) {
      return 'Centering timeout must be greater than zero';
    }
    if (solverConfig.timeoutSeconds < 1) {
      return 'Plate-solve timeout must be at least one second';
    }
    if (solverConfig.searchRadius != null &&
        (!solverConfig.searchRadius!.isFinite ||
            solverConfig.searchRadius! <= 0)) {
      return 'Plate-solve search radius must be greater than zero';
    }
    return null;
  }

  Future<CenteringResult> _runCentering({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    required CenteringConfig config,
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    // Live co-imaging framing offset: when this target centre belongs to a
    // co-imaging session this rig is in, slew/centre on `centre + the rig's
    // hub-assigned offset` so the rigs tile the field and reject
    // correlated/walking noise instead of all framing identically. The offset
    // resolves from the durable membership (no hub round-trip); a rig in no
    // covering session, or any failure, falls through to the raw target so
    // ordinary centering is unaffected. `targetRa` is app-canonical HOURS and
    // the offset helper works in degrees, so the conversion happens at the
    // boundary.
    final framed = await _resolveCoImagingFramedTarget(
      targetRaHours: targetRa,
      targetDecDeg: targetDec,
    );
    final effectiveRa = framed?.raHours ?? targetRa;
    final effectiveDec = framed?.decDeg ?? targetDec;
    if (_abortRequested) return _abortedResult(0, const []);
    return _centerOnTargetInternal(
      targetRa: effectiveRa,
      targetDec: effectiveDec,
      solverConfig: solverConfig,
      config: config,
      onStatusUpdate: onStatusUpdate,
    );
  }

  /// Resolve the co-imaging framing-offset-adjusted centre for a requested
  /// target (HOURS RA in / HOURS RA out), or null when this rig is not an active
  /// member of any co-imaging session covering the point. Defensive: a missing
  /// hub, an unbuilt provider (e.g. a centering unit test), or any resolver
  /// error logs a warning and returns null so centering proceeds on the raw
  /// target — the offset is an enhancement, never a precondition.
  Future<({double raHours, double decDeg})?> _resolveCoImagingFramedTarget({
    required double targetRaHours,
    required double targetDecDeg,
  }) async {
    try {
      final coImaging = _ref.read(coImagingSessionServiceProvider);
      final framed = await coImaging.framedCenterForPoint(
        centerRaDeg: targetRaHours * 15.0,
        centerDecDeg: targetDecDeg,
      );
      if (framed == null) return null;
      final raHours = framed.raDeg / 15.0;
      if (raHours == targetRaHours && framed.decDeg == targetDecDeg) {
        // Anchor slot (zero offset): nothing to apply.
        return null;
      }
      _ref
          .read(loggingServiceProvider)
          .info(
            'Co-imaging: framing this rig on its assigned coverage tile '
            '(${raHours.toStringAsFixed(4)}h, '
            '${framed.decDeg.toStringAsFixed(4)} deg) instead of the raw centre '
            '(${targetRaHours.toStringAsFixed(4)}h, '
            '${targetDecDeg.toStringAsFixed(4)} deg).',
            source: 'CenteringService',
          );
      return (raHours: raHours, decDeg: framed.decDeg);
    } catch (e) {
      _ref
          .read(loggingServiceProvider)
          .warning(
            'Co-imaging framing-offset resolve failed; centering on the raw '
            'target: $e',
            source: 'CenteringService',
          );
      return null;
    }
  }

  CenteringResult _abortedResult(
    int iteration,
    List<CenteringIteration> iterations,
  ) {
    return CenteringResult.failure(
      errorMessage: 'Aborted by user',
      iterations: iteration,
      iterationHistory: iterations,
    );
  }

  Future<CenteringResult> _centerOnTargetInternal({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    required CenteringConfig config,
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    final iterations = <CenteringIteration>[];
    final mountState = _ref.read(mountStateProvider);
    final cameraState = _ref.read(cameraStateProvider);

    // Validate mount and camera are connected
    if (mountState.connectionState != DeviceConnectionState.connected) {
      return CenteringResult.failure(
        errorMessage: 'Mount not connected',
        iterations: 0,
        iterationHistory: iterations,
      );
    }

    if (cameraState.connectionState != DeviceConnectionState.connected) {
      return CenteringResult.failure(
        errorMessage: 'Camera not connected',
        iterations: 0,
        iterationHistory: iterations,
      );
    }

    final imagingService = _ref.read(imagingServiceProvider);
    final plateSolveService = _ref.read(plateSolveServiceProvider);
    final deviceService = _ref.read(deviceServiceProvider);
    _ownedImagingService = imagingService;
    _ownedDeviceService = deviceService;

    // Fail before taking a throwaway exposure when the selected solver is not
    // usable. This also catches the case where another solver is installed but
    // the explicitly selected one is not configured.
    await plateSolveService.ensureSolverAvailable();
    if (_abortRequested) return _abortedResult(0, iterations);

    // A "Slew & Center" action reaches this service as soon as the mount
    // accepts the initial slew command; that command Future does not mean the
    // mount has physically settled. Query the live backend and wait before the
    // first exposure so the frame is not captured while stars are trailing.
    final mountId = mountState.deviceId;
    if (mountId != null) {
      var shouldWaitForInitialSlew = false;
      try {
        shouldWaitForInitialSlew = (await _backend.getMountStatus(
          mountId,
        )).slewing;
      } catch (_) {
        // Let the bounded poll tolerate transient query failures and surface a
        // typed error if the mount remains unreachable.
        shouldWaitForInitialSlew = true;
      }

      if (shouldWaitForInitialSlew) {
        onStatusUpdate?.call(
          CenteringStatus(
            state: CenteringState.slewing,
            currentIteration: 0,
            maxIterations: config.maxIterations,
            message: 'Waiting for the initial slew to settle...',
            iterationHistory: iterations,
          ),
        );
        _slewInFlight = true;
        try {
          await _waitForSlewComplete(mountId);
        } on CenteringMountUnresponsiveException catch (e) {
          if (_abortRequested) return _abortedResult(0, iterations);
          return CenteringResult.failure(
            errorMessage: e.toString(),
            iterations: 0,
            iterationHistory: iterations,
          );
        } on CenteringSlewTimeoutException catch (e) {
          if (_abortRequested) return _abortedResult(0, iterations);
          return CenteringResult.failure(
            errorMessage: e.toString(),
            iterations: 0,
            iterationHistory: iterations,
          );
        } finally {
          _slewInFlight = false;
        }
        if (_abortRequested) return _abortedResult(0, iterations);
      }
    }

    // Coordinates last commanded to the mount. Corrections are applied to THIS,
    // not to the original target: with `syncMount` off the correction is an
    // offset slew, and re-deriving it from the target each time would throw
    // away the correction already applied and oscillate.
    var commandedRa = targetRa;
    var commandedDec = targetDec;

    for (int iteration = 1; iteration <= config.maxIterations; iteration++) {
      if (_abortRequested) return _abortedResult(iteration - 1, iterations);

      // Update status
      onStatusUpdate?.call(
        CenteringStatus(
          state: CenteringState.exposing,
          currentIteration: iteration,
          maxIterations: config.maxIterations,
          message:
              'Taking centering image (iteration $iteration/${config.maxIterations})...',
          iterationHistory: iterations,
        ),
      );

      // Step 1: Take short exposure
      final currentExposure = _ref.read(exposureSettingsProvider);
      final exposureSettings = ExposureSettings(
        exposureTime: config.exposureTime,
        gain: config.gain ?? currentExposure.gain,
        offset: config.offset ?? currentExposure.offset,
        binningX: config.binning,
        binningY: config.binning,
        frameType: FrameType.light,
      );

      CapturedImageData? capturedImage;
      _captureInFlight = true;
      try {
        capturedImage = await imagingService.captureUtilityFrame(
          settings: exposureSettings,
          targetName: 'Centering',
        );
      } catch (e) {
        // Abort interrupts the in-flight exposure via cancelExposure() — the
        // imaging service surfaces this as a thrown error. Translate to an
        // explicit aborted result so the UI doesn't show "Centering Failed:
        // exposure cancelled".
        if (_abortRequested) return _abortedResult(iteration, iterations);
        final iter = CenteringIteration(
          iterationNumber: iteration,
          plateSolveSuccess: false,
          errorMessage: 'Image capture failed: $e',
          timestamp: DateTime.now(),
        );
        iterations.add(iter);

        return CenteringResult.failure(
          errorMessage: 'Failed to capture image: $e',
          iterations: iteration,
          iterationHistory: iterations,
        );
      } finally {
        _captureInFlight = false;
      }

      if (capturedImage == null) {
        // imagingService.cancelExposure() can return null instead of throwing;
        // attribute null-on-abort to the user, not to the camera.
        if (_abortRequested) return _abortedResult(iteration, iterations);

        final iter = CenteringIteration(
          iterationNumber: iteration,
          plateSolveSuccess: false,
          errorMessage: 'Image capture was cancelled',
          timestamp: DateTime.now(),
        );
        iterations.add(iter);

        return CenteringResult.failure(
          errorMessage: 'Image capture cancelled',
          iterations: iteration,
          iterationHistory: iterations,
        );
      }

      if (_abortRequested) return _abortedResult(iteration, iterations);

      // Step 2: Plate solve the image
      onStatusUpdate?.call(
        CenteringStatus(
          state: CenteringState.solving,
          currentIteration: iteration,
          maxIterations: config.maxIterations,
          message: 'Plate solving image...',
          iterationHistory: iterations,
          lastImagePath: capturedImage.filePath,
        ),
      );

      PlateSolveResult? solveResult;
      if (capturedImage.filePath != null) {
        solveResult = await plateSolveService.solveWithFallback(
          imagePath: capturedImage.filePath!,
          hintRaHours: solverConfig.hintRa ?? targetRa,
          hintDecDegrees: solverConfig.hintDec ?? targetDec,
          searchRadiusDegrees: solverConfig.searchRadius,
          timeoutSeconds: solverConfig.timeoutSeconds,
        );
      } else {
        final iter = CenteringIteration(
          iterationNumber: iteration,
          plateSolveSuccess: false,
          errorMessage: 'No image file path available',
          timestamp: DateTime.now(),
        );
        iterations.add(iter);

        return CenteringResult.failure(
          errorMessage: 'Image file not saved',
          iterations: iteration,
          iterationHistory: iterations,
        );
      }

      // A plate solver cannot currently be interrupted, so Abort may arrive
      // while the solve Future is in flight. Never use a late solution to sync
      // or slew the mount after the user has cancelled.
      if (_abortRequested) return _abortedResult(iteration, iterations);

      if (!solveResult.success) {
        final iter = CenteringIteration(
          iterationNumber: iteration,
          plateSolveSuccess: false,
          errorMessage: solveResult.error ?? 'Plate solve failed',
          timestamp: DateTime.now(),
        );
        iterations.add(iter);

        // If we still have iterations left, retry after a short delay
        // instead of immediately aborting. Transient solve failures (e.g.
        // clouds, tracking hiccup) often succeed on the next attempt.
        if (iteration < config.maxIterations) {
          onStatusUpdate?.call(
            CenteringStatus(
              state: CenteringState.solving,
              currentIteration: iteration,
              maxIterations: config.maxIterations,
              message: 'Plate solve failed, retrying in 500ms...',
              iterationHistory: iterations,
              lastImagePath: capturedImage.filePath,
            ),
          );
          await Future.delayed(const Duration(milliseconds: 500));
          if (_abortRequested) return _abortedResult(iteration, iterations);
          continue;
        }

        return CenteringResult.failure(
          errorMessage:
              'Plate solve failed after $iteration attempts: ${solveResult.error}',
          iterations: iteration,
          iterationHistory: iterations,
        );
      }

      // Step 3: Calculate offset from target.
      //
      // `solveResult.ra` is in DEGREES (solver/FITS frame). Normalise to
      // hours immediately so every downstream use in this iteration — the
      // offset math, the sync-to-solved-position slew, the status display and
      // the recorded iteration history — speaks the app-canonical hours frame
      // that `targetRa`, the mount and `CenteringStatus.solvedRa` all use.
      final solvedRa = _solvedRaHours(solveResult.ra);
      final solvedDec = solveResult.dec;
      final offset = _calculateOffset(targetRa, targetDec, solvedRa, solvedDec);

      final iter = CenteringIteration(
        iterationNumber: iteration,
        solvedRa: solvedRa,
        solvedDec: solvedDec,
        targetRa: targetRa,
        targetDec: targetDec,
        offsetArcsec: offset,
        offsetArcmin: offset / 60.0,
        plateSolveSuccess: true,
        timestamp: DateTime.now(),
      );
      iterations.add(iter);

      onStatusUpdate?.call(
        CenteringStatus(
          state: CenteringState.verifying,
          currentIteration: iteration,
          maxIterations: config.maxIterations,
          currentOffsetArcsec: offset,
          currentOffsetArcmin: offset / 60.0,
          message: 'Offset: ${(offset / 60.0).toStringAsFixed(2)} arcmin',
          iterationHistory: iterations,
          lastImagePath: capturedImage.filePath,
          solvedRa: solvedRa,
          solvedDec: solvedDec,
        ),
      );

      // Step 4: Check if within tolerance
      if (offset <= config.toleranceArcsec) {
        onStatusUpdate?.call(
          CenteringStatus(
            state: CenteringState.completed,
            currentIteration: iteration,
            maxIterations: config.maxIterations,
            currentOffsetArcsec: offset,
            currentOffsetArcmin: offset / 60.0,
            message: 'Target centered successfully!',
            iterationHistory: iterations,
            lastImagePath: capturedImage.filePath,
            solvedRa: solvedRa,
            solvedDec: solvedDec,
          ),
        );

        // Smart notification for centering completion
        final offsetArcmin = offset / 60.0;
        _ref
            .read(smartNotificationServiceProvider)
            .showSuccessIfNotOnScreens(
              message:
                  'Target centered (offset: ${offsetArcmin.toStringAsFixed(2)} arcmin)',
              relevantScreens: [AppScreen.imaging, AppScreen.sequencer],
              title: 'Centering Complete',
            );

        return CenteringResult.success(
          finalOffsetArcsec: offset,
          iterations: iteration,
          iterationHistory: iterations,
        );
      }

      // Step 5: Slew to correct position
      onStatusUpdate?.call(
        CenteringStatus(
          state: CenteringState.slewing,
          currentIteration: iteration,
          maxIterations: config.maxIterations,
          currentOffsetArcsec: offset,
          currentOffsetArcmin: offset / 60.0,
          message: 'Slewing to target...',
          iterationHistory: iterations,
          lastImagePath: capturedImage.filePath,
          solvedRa: solvedRa,
          solvedDec: solvedDec,
        ),
      );

      _slewInFlight = true;
      try {
        if (config.syncMount) {
          // Tell the mount where it ACTUALLY is (solved position, RA in hours
          // like every other coordinate here), then re-slew to the target: the
          // slew now moves by the true pointing error.
          await deviceService.syncMountToCoordinates(solvedRa, solvedDec);
          if (_abortRequested) return _abortedResult(iteration, iterations);
          commandedRa = targetRa;
          commandedDec = targetDec;
          await deviceService.slewMountToCoordinates(commandedRa, commandedDec);
        } else {
          // No sync: correct by offsetting the commanded coordinates by the
          // measured error. Re-issuing the target unchanged is what made
          // centering repeat a bit-identical slew until it ran out of
          // iterations.
          commandedRa = _normalizedRaHours(commandedRa - (solvedRa - targetRa));
          commandedDec = _clampedDecDegrees(
            commandedDec - (solvedDec - targetDec),
          );
          await deviceService.slewMountToCoordinates(commandedRa, commandedDec);
        }
        if (_abortRequested) return _abortedResult(iteration, iterations);

        // Wait for slew to complete by polling mount status.
        final correctionMountId = mountState.deviceId;
        if (correctionMountId != null) {
          await _waitForSlewComplete(correctionMountId);
        } else {
          await Future.delayed(const Duration(seconds: 2));
        }
      } on CenteringMountUnresponsiveException catch (e) {
        if (_abortRequested) return _abortedResult(iteration, iterations);
        return CenteringResult.failure(
          errorMessage: e.toString(),
          iterations: iteration,
          iterationHistory: iterations,
        );
      } on CenteringSlewTimeoutException catch (e) {
        if (_abortRequested) return _abortedResult(iteration, iterations);
        return CenteringResult.failure(
          errorMessage: e.toString(),
          iterations: iteration,
          iterationHistory: iterations,
        );
      } catch (e) {
        // Abort triggers abortMountSlew() which surfaces as a thrown error
        // from the in-flight slew future; report as user abort, not failure.
        if (_abortRequested) return _abortedResult(iteration, iterations);
        return CenteringResult.failure(
          errorMessage: 'Mount slew failed: $e',
          iterations: iteration,
          iterationHistory: iterations,
        );
      } finally {
        _slewInFlight = false;
      }

      if (_abortRequested) return _abortedResult(iteration, iterations);

      // Small delay before next iteration
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Max iterations reached without achieving tolerance
    final lastOffset = iterations.isNotEmpty
        ? iterations.last.offsetArcsec
        : null;
    return CenteringResult.failure(
      errorMessage:
          'Maximum iterations (${config.maxIterations}) reached. Final offset: ${lastOffset != null ? (lastOffset / 60.0).toStringAsFixed(2) : 'unknown'} arcmin',
      iterations: config.maxIterations,
      iterationHistory: iterations,
    );
  }
}
