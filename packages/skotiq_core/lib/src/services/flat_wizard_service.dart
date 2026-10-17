import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../backend/skotiq_backend.dart';
import '../backend/network_backend.dart';
import '../models/flat_wizard/flat_capture_config.dart';
import '../models/flat_wizard/flat_wizard_settings.dart';
import '../models/sequence/sequence_models.dart';
import '../models/imaging/imaging_models.dart';
import '../providers/backend_provider.dart';
import '../providers/flat_wizard_provider.dart';
import 'sky_brightness_tracker.dart';
import 'flat_exposure_calculator.dart';
part 'flat_wizard_service/flat_wizard_models.dart';
part 'flat_wizard_service/exposure_events.dart';
part 'flat_wizard_service/exposure_event_keys.dart';

/// Service for flat frame calibration and sequence generation
class FlatWizardService {
  final SkotiqBackend backend;

  // Image download timeout, from
  // [FlatWizardGlobalSettings.imageDownloadTimeoutSeconds] (default 60 s), so
  // very large sensors or slow USB hubs can be tuned without a recompile.
  final Duration imageDownloadTimeout;

  /// Default maximum binary-search iterations used by [quickCalibrate]. Wired
  /// from [FlatWizardGlobalSettings.maxIterations] (default 8).
  final int defaultMaxIterations;

  FlatWizardService(
    this.backend, {
    this.imageDownloadTimeout = const Duration(seconds: 60),
    this.defaultMaxIterations = 8,
    this.quickMinExposure = 0.001,
    this.quickMaxExposure = 30.0,
  });

  /// Build a service from [FlatWizardGlobalSettings] so settings-driven defaults
  /// flow into the service in one place.
  factory FlatWizardService.fromSettings(
    SkotiqBackend backend,
    FlatWizardGlobalSettings settings,
  ) {
    return FlatWizardService(
      backend,
      imageDownloadTimeout: Duration(
        seconds: settings.imageDownloadTimeoutSeconds,
      ),
      defaultMaxIterations: settings.maxIterations,
      quickMinExposure: settings.minExposure,
      quickMaxExposure: settings.maxExposure,
    );
  }

  /// Resolve the effective, capability-aware capture configuration for a flat
  /// run from the CONNECTED camera plus the active profile.
  ///
  /// This is the single source of truth for the effective ADU range, the gain/
  /// offset actually commanded, and the binning — used by the UI preview, the
  /// backend command, the FITS header, and the DB record so they cannot drift.
  ///
  /// Host authority (defect: remote mode): [backend.getCameraStatus] and
  /// [backend.getCameraCapabilities] route to the master on a [NetworkBackend],
  /// so the host — not the phone — defines the range and capability limits. Both
  /// Calls are best-effort so the UI can still render a disconnected/partial
  /// preview, but the returned [FlatCaptureConfig.rangeKnown] tells capture
  /// callers whether the ADU range is authoritative enough to automate.
  static Future<FlatCaptureConfig> resolveCaptureConfig({
    required SkotiqBackend backend,
    required String deviceId,
    int? profileDefaultGain,
    int? profileDefaultOffset,
    int? profileBinX,
    int? profileBinY,
    int? currentGain,
    int? currentOffset,
    int? fallbackBinX,
    int? fallbackBinY,
  }) async {
    CameraStatus? status;
    CameraCapabilities? caps;
    // Bare `catch` (not `on Exception`): an unavailable/disconnected device may
    // surface as an Error, and a capability probe must never abort the run —
    // but a failed probe degrades the resolved config (guessed range, default
    // gain), so it is logged rather than silently swallowed.
    try {
      status = await backend.getCameraStatus(deviceId);
    } catch (e) {
      developer.log(
        'FlatWizard: camera status probe failed for $deviceId: $e',
        name: 'FlatWizardService',
        level: 900,
      );
    }
    try {
      caps = await backend.getCameraCapabilities(deviceId);
    } catch (e) {
      developer.log(
        'FlatWizard: camera capabilities probe failed for $deviceId: $e',
        name: 'FlatWizardService',
        level: 900,
      );
    }

    // Effective full-scale ADU
    // The DRIVER-reported max-ADU is authoritative, and bit depth is only a
    // last-resort fallback when no driver value exists.
    //
    // Bit depth is ADC resolution, not the pixel container: 12- and 14-bit
    // astro CMOS drivers left-justify their samples into the 16-bit word, so an
    // ASI1600MM (bitDepth 12) reads up to 65504. Capping full scale at
    // `(1 << bitDepth) - 1` would put the flat target below such a camera's own
    // bias floor and convergence could never be reached.
    //
    // Measured ADU (`FlatFrameCapture.adu` = `image.stats.mean`) is in pixel
    // container units, so the target scales by the container's full scale,
    // which is what `CameraStatus.maxAdu` reports. A driver overstating its
    // MaxADU only lengthens flats.
    final bitDepth = caps?.bitDepth;
    int? maxAduCandidate;
    if (status != null && status.maxAdu > 0) {
      maxAduCandidate = status.maxAdu;
    } else if (bitDepth != null && bitDepth >= 1 && bitDepth <= 32) {
      maxAduCandidate = (1 << bitDepth) - 1;
    }
    final rangeKnown = maxAduCandidate != null;
    final maxAdu = maxAduCandidate ?? FlatExposureCalculator.fallbackMaxAdu;

    // Gain
    // Unknown is NOT permission to command a control. Fail closed to the
    // driver default unless at least one authoritative surface explicitly
    // reports support and neither explicitly rejects it.
    final gainSupported =
        (caps?.canSetGain == true || status?.canSetGain == true) &&
        caps?.canSetGain != false &&
        status?.canSetGain != false;
    int? gain;
    if (gainSupported) {
      // profile default wins, then the live connected value. Null => the
      // camera/driver default (NOT numeric zero).
      gain = profileDefaultGain ?? currentGain ?? status?.gain;
      gain = _clampToRange(gain, caps?.gainMin, caps?.gainMax);
    }

    // Offset
    final offsetSupported =
        (caps?.canSetOffset == true || status?.canSetOffset == true) &&
        caps?.canSetOffset != false &&
        status?.canSetOffset != false;
    int? offset;
    if (offsetSupported) {
      offset = profileDefaultOffset ?? currentOffset ?? status?.offset;
      offset = _clampToRange(offset, caps?.offsetMin, caps?.offsetMax);
    }

    // Binning
    var binX = (profileBinX ?? fallbackBinX ?? 1);
    var binY = (profileBinY ?? fallbackBinY ?? 1);
    if (binX < 1) binX = 1;
    if (binY < 1) binY = 1;
    // Binning has no status-level capability flag, so only an explicit camera
    // capability enables it. Unknown drivers remain at the safe 1x1 default.
    final canBin = caps?.canBin == true;
    final canAsymmetricBin = caps?.canAsymmetricBin ?? false;
    if (!canBin) {
      // Camera cannot bin — never command anything but 1×1.
      binX = 1;
      binY = 1;
    } else {
      final mbx = caps?.maxBinX;
      final mby = caps?.maxBinY;
      if (mbx != null && mbx >= 1 && binX > mbx) binX = mbx;
      if (mby != null && mby >= 1 && binY > mby) binY = mby;
      // Only force symmetric when we KNOW asymmetric binning is unsupported.
      if (caps != null && !canAsymmetricBin && binX != binY) binY = binX;
    }

    return FlatCaptureConfig(
      maxAdu: maxAdu,
      bitDepth: bitDepth,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      canSetGain: gainSupported,
      canSetOffset: offsetSupported,
      gainMin: caps?.gainMin,
      gainMax: caps?.gainMax,
      offsetMin: caps?.offsetMin,
      offsetMax: caps?.offsetMax,
      canBin: canBin,
      canAsymmetricBin: canAsymmetricBin,
      maxBinX: caps?.maxBinX ?? binX,
      maxBinY: caps?.maxBinY ?? binY,
      hostAuthoritative: backend is NetworkBackend,
      capabilitiesKnown: caps != null,
      rangeKnown: rangeKnown,
    );
  }

  /// Calculate next exposure time to reach target ADU using proportional adjustment
  ///
  /// Uses a conservative approach with safety limits to avoid overshooting:
  /// - Limits adjustment ratio to prevent extreme jumps
  /// - Applies minimum/maximum exposure bounds
  /// - Uses logarithmic damping for large adjustments
  double calculateNextExposure({
    required double currentExposure,
    required double currentAdu,
    required double targetAdu,
    required double minExposure,
    required double maxExposure,
  }) {
    // Avoid division by zero
    if (currentAdu <= 0) {
      return (minExposure + maxExposure) / 2;
    }

    // Calculate raw ratio
    final ratio = targetAdu / currentAdu;

    // Apply safety limits to prevent extreme jumps
    // Allow max 3x increase or 1/3x decrease per iteration
    final clampedRatio = ratio.clamp(0.33, 3.0);

    // For large adjustments, use logarithmic damping
    final adjustedRatio = clampedRatio > 2.0 || clampedRatio < 0.5
        ? 1.0 +
              (clampedRatio - 1.0) *
                  0.7 // Reduce aggressive changes
        : clampedRatio;

    // Calculate next exposure
    final nextExposure = currentExposure * adjustedRatio;

    // Clamp to valid range
    return nextExposure.clamp(minExposure, maxExposure);
  }

  /// Authoritative single-frame capture used by BOTH the calibration solver and
  /// the frame-capture loop.
  ///
  /// Correctness guarantees this centralizes:
  ///   * Subscribes to the event stream BEFORE starting the exposure, so a fast
  ///     completion cannot fire before we are listening.
  ///   * Settles on the FIRST terminal exposure event correlated to
  ///     [deviceId] (see [_classifyExposureEvent]) — never a fixed delay, so a
  ///     slow readout is waited out and a stray/unrelated-device event is
  ///     ignored.
  ///   * Cooperative cancel: if [cancelToken] is (or becomes) cancelled while
  ///     the exposure is in flight, [cameraAbortExposure] is called EXACTLY
  ///     once, then we wait a bounded time for the hardware to settle before
  ///     returning [FlatFrameOutcome.cancelled] — the caller then starts no
  ///     further frame.
  ///   * Timeout: an exposure that does not reach a terminal event within the
  ///     overall bound is aborted EXACTLY once and awaited-to-settle just like a
  ///     cancel. The stale prior image is NEVER read as the timed-out frame. If
  ///     the abort throws or idle cannot be confirmed the returned capture has
  ///     `cameraQuiescent == false` so the caller stops the run.
  ///   * Only [FlatFrameOutcome.completed] fetches the image; a null image is
  ///     reported as [FlatFrameOutcome.failed], not a silent success.
  ///
  /// [gain]/[offset] are nullable: `null` commands the camera/driver default
  /// (NOT numeric zero) and is passed straight through to the backend.
  Future<FlatFrameCapture> exposeAndAwait({
    required String deviceId,
    required double exposureTime,
    int? gain,
    int? offset,
    String? filterName,
    int? filterPosition,
    String? filterWheelDeviceId,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
  }) async {
    // A cancel that arrived before we even started: do not touch the hardware.
    if (cancelToken?.isCancelled ?? false) {
      return const FlatFrameCapture(outcome: FlatFrameOutcome.cancelled);
    }

    try {
      // Change filter if specified and a filter wheel device ID is available.
      if (filterWheelDeviceId != null) {
        if (filterName != null) {
          await backend.filterWheelSetByName(filterWheelDeviceId, filterName);
        } else if (filterPosition != null) {
          await backend.filterWheelSetPosition(
            filterWheelDeviceId,
            filterPosition,
          );
        }
      }

      if (cancelToken?.isCancelled ?? false) {
        return const FlatFrameCapture(outcome: FlatFrameOutcome.cancelled);
      }

      // Subscribe BEFORE starting the exposure to avoid a lost-wakeup race.
      final terminal = Completer<_ExposureEventKind>();
      final subscription = backend.eventStream.listen((event) {
        final kind = _classifyExposureEvent(event, deviceId);
        if (kind == _ExposureEventKind.notTerminal) return;
        if (!terminal.isCompleted) terminal.complete(kind);
      });

      var aborted = false;

      // Abort the in-flight exposure EXACTLY once, then wait a bounded time for
      // the authoritative terminal settle event so the driver is provably
      // quiescent before the caller moves on (or stops). Returns whether the
      // camera is confirmed idle: false when the abort itself threw or the
      // settle event never arrived — in which case the camera state is UNKNOWN.
      Future<bool> abortAndSettle() async {
        if (!aborted) {
          aborted = true;
          try {
            await backend.cameraAbortExposure(deviceId);
          } catch (e) {
            developer.log(
              'FlatWizardService: cameraAbortExposure failed: $e',
              name: 'FlatWizardService',
              level: 900,
              error: e,
            );
            return false; // abort failed → camera state unknown
          }
        }
        var settled = true;
        await terminal.future.timeout(
          abortSettleTimeout,
          onTimeout: () {
            settled = false; // idle could not be confirmed in time
            return _ExposureEventKind.cancelled;
          },
        );
        return settled;
      }

      try {
        await backend.cameraStartExposure(
          deviceId: deviceId,
          exposureTime: exposureTime,
          frameType: FrameType.flat,
          gain: gain,
          offset: offset,
          binX: binX,
          binY: binY,
        );

        // Race the authoritative terminal event against a cancel request and a
        // generous overall timeout (exposure + readout/download headroom).
        // `whenCancelled` completes immediately if the token was already
        // cancelled just before we got here, so a late cancel is never missed.
        final overall =
            overallTimeout ??
            Duration(milliseconds: (exposureTime * 1000).toInt() + 30000);
        final futures = <Future<_CaptureWake>>[
          terminal.future.then(_CaptureWake.event),
        ];
        if (cancelToken != null) {
          futures.add(
            cancelToken.whenCancelled.then((_) => _CaptureWake.cancel()),
          );
        }
        final wake = await Future.any(
          futures,
        ).timeout(overall, onTimeout: _CaptureWake.timeout);

        if (wake.isTimeout) {
          // The exposure never reached a terminal event. Abort it (once) and
          // wait for the camera to settle — do NOT read `getLastImage`, which
          // would hand back a STALE prior frame as if it were this exposure.
          developer.log(
            'FlatWizardService: Exposure timed out after '
            '${exposureTime + 30}s; aborting',
            name: 'FlatWizardService',
            level: 900,
          );
          final quiescent = await abortAndSettle();
          return FlatFrameCapture(
            outcome: FlatFrameOutcome.timedOut,
            cameraQuiescent: quiescent,
            error: quiescent
                ? 'Exposure timed out (camera aborted and idle)'
                : 'Exposure timed out and the camera could not be confirmed '
                      'idle — check the camera',
          );
        }

        if (wake.isCancel) {
          // Cancel requested mid-exposure: abort the hardware EXACTLY once,
          // then wait a bounded time for the terminal settle event so the
          // driver is quiescent before the caller moves on (or stops).
          final quiescent = await abortAndSettle();
          return FlatFrameCapture(
            outcome: FlatFrameOutcome.cancelled,
            cameraQuiescent: quiescent,
          );
        }

        final kind = wake.kind!;
        if (kind == _ExposureEventKind.cancelled) {
          return const FlatFrameCapture(outcome: FlatFrameOutcome.cancelled);
        }
        if (kind == _ExposureEventKind.failed) {
          return const FlatFrameCapture(
            outcome: FlatFrameOutcome.failed,
            error: 'Exposure reported failure',
          );
        }
      } finally {
        await subscription.cancel();
      }

      // Terminal completed-ok: retrieve the image (bounded download timeout).
      final image = await backend
          .cameraGetLastImage(deviceId)
          .timeout(
            imageDownloadTimeout,
            onTimeout: () {
              developer.log(
                'FlatWizardService: Image retrieval timed out after '
                '${imageDownloadTimeout.inSeconds}s',
                name: 'FlatWizardService',
                level: 900,
              );
              return null;
            },
          );
      if (image == null) {
        developer.log(
          'FlatWizardService: Failed to retrieve captured frame',
          name: 'FlatWizardService',
          level: 900,
        );
        return const FlatFrameCapture(
          outcome: FlatFrameOutcome.failed,
          error: 'Failed to retrieve captured frame',
        );
      }
      return FlatFrameCapture(
        outcome: FlatFrameOutcome.completed,
        image: image,
      );
    } catch (e) {
      developer.log(
        'FlatWizardService: Error capturing frame: $e',
        name: 'FlatWizardService',
        level: 1000,
        error: e,
      );
      return FlatFrameCapture(
        outcome: FlatFrameOutcome.failed,
        error: e.toString(),
      );
    }
  }

  /// Capture a single test frame; returns its mean ADU and the full outcome.
  ///
  /// Thin wrapper over [exposeAndAwait]: `adu` is the mean ADU on a completed
  /// capture and null on any non-completed outcome (failure, cancellation,
  /// timeout). Waits for the authoritative completion event rather than a fixed
  /// delay. `outcome` carries what the bare ADU cannot — a timeout (halt the
  /// run) is distinguishable from a plain capture failure — and it is returned
  /// rather than stashed on the service because two callers share one instance
  /// (the GUI wizard and the headless API) with nothing serialising them; a
  /// field here would let one solver read the other's frame.
  ///
  /// This is the single overridable capture seam the calibration solvers route
  /// through, so a test double can inject ADU samples without reimplementing
  /// the event plumbing. A double that returns a null `outcome` is treated as
  /// an ordinary completed measurement whenever `adu` is non-null.
  Future<({double? adu, FlatFrameCapture? outcome})> captureTestFrame({
    required String deviceId,
    required double exposureTime,
    int? gain,
    int? offset,
    String? filterName,
    int? filterPosition,
    String? filterWheelDeviceId,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
  }) async {
    final capture = await exposeAndAwait(
      deviceId: deviceId,
      exposureTime: exposureTime,
      gain: gain,
      offset: offset,
      filterName: filterName,
      filterPosition: filterPosition,
      filterWheelDeviceId: filterWheelDeviceId,
      binX: binX,
      binY: binY,
      cancelToken: cancelToken,
      abortSettleTimeout: abortSettleTimeout,
      overallTimeout: overallTimeout,
    );
    return (adu: capture.adu, outcome: capture);
  }

  /// Run iterative calibration to find optimal exposure for target ADU
  ///
  /// Uses binary search-like algorithm with adaptive step sizing:
  /// 1. Start with initial exposure estimate
  /// 2. Capture test frame and measure ADU
  /// 3. Calculate next exposure using proportional adjustment
  /// 4. Repeat until within tolerance or max iterations reached
  ///
  /// Returns [FlatResult] with optimal exposure and final ADU
  Future<FlatResult> calibrateFilter({
    required String deviceId,
    required String filter,
    int? gain,
    int? offset,
    required double targetAdu,
    required double tolerance,
    required double minExposure,
    required double maxExposure,
    int maxIterations = 10,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
    void Function(int iteration, double exposure, double adu)? onProgress,
  }) async {
    // Start with midpoint exposure
    double exposure = math.sqrt(minExposure * maxExposure);
    double? lastAdu;
    int iteration = 0;

    developer.log(
      'FlatWizardService: Starting calibration for filter "$filter"\n'
      '  Target ADU: ${targetAdu.toStringAsFixed(0)}\n'
      '  Tolerance: ±${tolerance.toStringAsFixed(1)}%\n'
      '  Exposure range: ${minExposure.toStringAsFixed(3)}s - ${maxExposure.toStringAsFixed(3)}s',
      name: 'FlatWizardService',
      level: 800,
    );

    for (iteration = 1; iteration <= maxIterations; iteration++) {
      // Cooperative cancel BETWEEN iterations: a cancel requested during the
      // previous exposure (or the settle wait) stops the solver immediately
      // instead of running another test frame.
      if (cancelToken?.isCancelled ?? false) {
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          cancelled: true,
          iterations: iteration - 1,
          errorMessage: 'Cancelled',
        );
      }

      developer.log(
        'FlatWizardService: Iteration $iteration/$maxIterations - '
        'Testing exposure: ${exposure.toStringAsFixed(3)}s',
        name: 'FlatWizardService',
        level: 800,
      );

      // Measure through the overridable [captureTestFrame] seam (so tests can
      // inject ADU samples). The FULL outcome comes back with the measurement,
      // so a cancel that lands mid-exposure aborts the hardware and a timeout is
      // distinguishable from a plain capture failure.
      final (:adu, :outcome) = await captureTestFrame(
        deviceId: deviceId,
        exposureTime: exposure,
        gain: gain,
        offset: offset,
        filterName: filter,
        binX: binX,
        binY: binY,
        cancelToken: cancelToken,
        abortSettleTimeout: abortSettleTimeout,
        overallTimeout: overallTimeout,
      );

      if (outcome != null && outcome.isCancelled) {
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          cancelled: true,
          iterations: iteration,
          errorMessage: 'Cancelled',
        );
      }
      if (outcome != null && outcome.isTimedOut) {
        // A timeout means the exposure pipeline is misbehaving; the run must
        // STOP (fail-safe) rather than risk overlapping the next exposure.
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          iterations: iteration,
          haltRun: true,
          cameraStateUnknown: !outcome.cameraQuiescent,
          errorMessage: outcome.error ?? 'Exposure timed out',
        );
      }
      if (adu == null) {
        // A terminal failure/null image (or a pre-start cancel). The camera IS
        // settled, so the run may continue to the next filter (this filter is
        // marked failed). The exact cause is logged in [exposeAndAwait].
        if (cancelToken?.isCancelled ?? false) {
          return FlatResult(
            filter: filter,
            exposure: exposure,
            adu: lastAdu ?? 0,
            success: false,
            cancelled: true,
            iterations: iteration,
            errorMessage: 'Cancelled',
          );
        }
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          iterations: iteration,
          errorMessage: 'Failed to capture test frame',
        );
      }

      lastAdu = adu;
      developer.log(
        'FlatWizardService: Measured ADU: ${adu.toStringAsFixed(0)}',
        name: 'FlatWizardService',
        level: 800,
      );

      // Notify progress callback
      onProgress?.call(iteration, exposure, adu);

      // Check if within tolerance
      final error = ((adu - targetAdu).abs() / targetAdu) * 100;
      if (error <= tolerance) {
        developer.log(
          'FlatWizardService: SUCCESS! Found optimal exposure: '
          '${exposure.toStringAsFixed(3)}s (ADU: ${adu.toStringAsFixed(0)}, '
          'error: ${error.toStringAsFixed(2)}%)',
          name: 'FlatWizardService',
          level: 800,
        );
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: adu,
          success: true,
          iterations: iteration,
        );
      }

      // Calculate next exposure
      final nextExposure = calculateNextExposure(
        currentExposure: exposure,
        currentAdu: adu,
        targetAdu: targetAdu,
        minExposure: minExposure,
        maxExposure: maxExposure,
      );

      // Check for convergence (exposure not changing significantly)
      if ((nextExposure - exposure).abs() < 0.001) {
        developer.log(
          'FlatWizardService: Converged at exposure: ${exposure.toStringAsFixed(3)}s '
          '(ADU: ${adu.toStringAsFixed(0)})',
          name: 'FlatWizardService',
          level: 800,
        );
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: adu,
          success: error <= tolerance * 2, // Accept if within 2x tolerance
          iterations: iteration,
        );
      }

      exposure = nextExposure;
    }

    // Max iterations reached
    developer.log(
      'FlatWizardService: Max iterations reached. Best result: '
      '${exposure.toStringAsFixed(3)}s (ADU: ${lastAdu?.toStringAsFixed(0) ?? "N/A"})',
      name: 'FlatWizardService',
      level: 900,
    );
    return FlatResult(
      filter: filter,
      exposure: exposure,
      adu: lastAdu ?? 0,
      success: false,
      iterations: maxIterations,
      errorMessage: 'Max iterations reached without convergence',
    );
  }

  /// Calibrate filter with rate tracking for sky flats
  ///
  /// Uses predictive exposure calculation based on sky brightness rate
  Future<FlatResult> calibrateFilterWithRateTracking({
    required String deviceId,
    required String filter,
    int? gain,
    int? offset,
    required double targetAdu,
    required double tolerance,
    required double minExposure,
    required double maxExposure,
    required SkyBrightnessTracker brightnessTracker,
    double? historicalExposure,
    int maxIterations = 3, // Fewer iterations for sky flats (speed matters)
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
    void Function(int iteration, double exposure, double adu, String status)?
    onProgress,
  }) async {
    // Get starting exposure
    double exposure = FlatExposureCalculator.getStartingExposure(
      historicalExposure: historicalExposure,
      minExposure: minExposure,
      maxExposure: maxExposure,
      currentSkyAduRate: brightnessTracker.calculateRate(),
    );

    double? lastAdu;
    int iteration = 0;

    for (iteration = 1; iteration <= maxIterations; iteration++) {
      if (cancelToken?.isCancelled ?? false) {
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          cancelled: true,
          iterations: iteration - 1,
          errorMessage: 'Cancelled',
        );
      }

      onProgress?.call(iteration, exposure, lastAdu ?? 0, 'Testing exposure');

      // Measure through the overridable [captureTestFrame] seam; the FULL
      // outcome comes back with it (cancel-aware; a timeout halts the whole run
      // fail-safe).
      final (:adu, :outcome) = await captureTestFrame(
        deviceId: deviceId,
        exposureTime: exposure,
        gain: gain,
        offset: offset,
        filterName: filter,
        binX: binX,
        binY: binY,
        cancelToken: cancelToken,
        abortSettleTimeout: abortSettleTimeout,
        overallTimeout: overallTimeout,
      );

      if (outcome != null && outcome.isCancelled) {
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          cancelled: true,
          iterations: iteration,
          errorMessage: 'Cancelled',
        );
      }
      if (outcome != null && outcome.isTimedOut) {
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          iterations: iteration,
          haltRun: true,
          cameraStateUnknown: !outcome.cameraQuiescent,
          errorMessage: outcome.error ?? 'Exposure timed out',
        );
      }
      if (adu == null) {
        if (cancelToken?.isCancelled ?? false) {
          return FlatResult(
            filter: filter,
            exposure: exposure,
            adu: lastAdu ?? 0,
            success: false,
            cancelled: true,
            iterations: iteration,
            errorMessage: 'Cancelled',
          );
        }
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: lastAdu ?? 0,
          success: false,
          iterations: iteration,
          errorMessage: 'Failed to capture test frame',
        );
      }

      lastAdu = adu;

      // Update brightness tracker
      brightnessTracker.addSample(
        adu: adu,
        exposureTime: exposure,
        timestamp: DateTime.now(),
      );

      // Check if within tolerance
      final toleranceAdu = targetAdu * tolerance / 100.0;
      if ((adu - targetAdu).abs() <= toleranceAdu) {
        onProgress?.call(iteration, exposure, adu, 'On target');
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: adu,
          success: true,
          iterations: iteration,
        );
      }

      // Calculate next exposure using rate-aware prediction
      final predictedExposure = brightnessTracker.calculateOptimalExposure(
        targetAdu: targetAdu,
        minExposure: minExposure,
        maxExposure: maxExposure,
      );

      if (predictedExposure != null) {
        exposure = predictedExposure;
      } else {
        // Fall back to the single canonical proportional-adjustment engine
        // (the same [calculateNextExposure] that drives the standalone wizard
        // screen and the headless /api/flat-wizard handlers via
        // [calibrateFilter]).
        exposure = calculateNextExposure(
          currentExposure: exposure,
          currentAdu: adu,
          targetAdu: targetAdu,
          minExposure: minExposure,
          maxExposure: maxExposure,
        );
      }

      // Check limits
      final limitStatus = FlatExposureCalculator.checkLimits(
        exposure: exposure,
        measuredAdu: adu,
        targetAdu: targetAdu,
        minExposure: minExposure,
        maxExposure: maxExposure,
        tolerancePercent: tolerance,
      );

      if (limitStatus == ExposureLimitStatus.maxExposureReached) {
        onProgress?.call(iteration, exposure, adu, 'Max exposure reached');
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: adu,
          success: false,
          iterations: iteration,
          errorMessage: 'Max exposure reached but still under target',
        );
      }

      if (limitStatus == ExposureLimitStatus.minExposureReached) {
        onProgress?.call(iteration, exposure, adu, 'Min exposure reached');
        return FlatResult(
          filter: filter,
          exposure: exposure,
          adu: adu,
          success: false,
          iterations: iteration,
          errorMessage: 'Min exposure reached but still over target',
        );
      }
    }

    // Return best effort
    return FlatResult(
      filter: filter,
      exposure: exposure,
      adu: lastAdu ?? 0,
      success: false,
      iterations: maxIterations,
      errorMessage: 'Did not converge within $maxIterations iterations',
    );
  }

  /// Calibrate multiple filters in sequence
  ///
  /// Runs calibration for each filter and returns list of results
  Future<List<FlatResult>> calibrateMultipleFilters({
    required String deviceId,
    required List<String> filters,
    int? gain,
    int? offset,
    required double targetAdu,
    required double tolerance,
    required double minExposure,
    required double maxExposure,
    int maxIterations = 10,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
    void Function(String filter, int iteration, double exposure, double adu)?
    onProgress,
    void Function(String filter, FlatResult result)? onFilterComplete,
  }) async {
    final results = <FlatResult>[];

    for (final filter in filters) {
      if (cancelToken?.isCancelled ?? false) break;

      developer.log(
        'FlatWizardService: Starting calibration for filter: $filter',
        name: 'FlatWizardService',
        level: 800,
      );

      final result = await calibrateFilter(
        deviceId: deviceId,
        filter: filter,
        gain: gain,
        offset: offset,
        targetAdu: targetAdu,
        tolerance: tolerance,
        minExposure: minExposure,
        maxExposure: maxExposure,
        maxIterations: maxIterations,
        binX: binX,
        binY: binY,
        cancelToken: cancelToken,
        abortSettleTimeout: abortSettleTimeout,
        overallTimeout: overallTimeout,
        onProgress: (iteration, exposure, adu) {
          onProgress?.call(filter, iteration, exposure, adu);
        },
      );

      results.add(result);
      onFilterComplete?.call(filter, result);

      if (result.cancelled) break;
      // Fail-safe: a timeout/uncertain-camera result stops the whole batch, not
      // just this filter.
      if (result.haltRun) break;

      if (!result.success) {
        developer.log(
          'FlatWizardService: Warning - Calibration failed for filter: $filter',
          name: 'FlatWizardService',
          level: 900,
        );
      }
    }

    return results;
  }

  /// Generate sequence nodes from flat calibration results
  ///
  /// Creates ExposureNode for each successful calibration with specified frame count
  /// Nodes are created as independent flat capture sequences
  List<SequenceNode> generateFlatSequence({
    required List<FlatResult> calibrations,
    required int framesPerFilter,
    int binX = 1,
    int binY = 1,
    int? gain,
    int? offset,
    bool onlySuccessful = true,
  }) {
    final nodes = <SequenceNode>[];
    int orderIndex = 0;

    for (final cal in calibrations) {
      // Skip failed calibrations if requested
      if (onlySuccessful && !cal.success) {
        developer.log(
          'FlatWizardService: Skipping failed calibration for filter: ${cal.filter}',
          name: 'FlatWizardService',
          level: 800,
        );
        continue;
      }

      // Create exposure node for this filter
      final node = ExposureNode(
        id: const Uuid().v4(),
        name: 'Flat ${cal.filter}',
        durationSecs: cal.exposure,
        count: framesPerFilter,
        filter: cal.filter,
        gain: gain,
        offset: offset,
        binning: _binningFromInts(binX, binY),
        frameType: FrameType.flat,
        orderIndex: orderIndex++,
        isEnabled: true,
      );

      nodes.add(node);
      developer.log(
        'FlatWizardService: Generated sequence node - '
        'Filter: ${cal.filter}, Exposure: ${cal.exposure.toStringAsFixed(3)}s, '
        'Count: $framesPerFilter',
        name: 'FlatWizardService',
        level: 800,
      );
    }

    return nodes;
  }

  /// Generate a complete flat sequence with optional sequence wrapper
  ///
  /// Creates InstructionSetNode containing all flat exposure nodes
  /// Returns a complete Sequence ready to be saved or executed
  Sequence generateCompleteSequence({
    required List<FlatResult> calibrations,
    required int framesPerFilter,
    String sequenceName = 'Flat Frame Sequence',
    String? description,
    int binX = 1,
    int binY = 1,
    int? gain,
    int? offset,
    bool onlySuccessful = true,
  }) {
    // Generate flat capture nodes
    final captureNodes = generateFlatSequence(
      calibrations: calibrations,
      framesPerFilter: framesPerFilter,
      binX: binX,
      binY: binY,
      gain: gain,
      offset: offset,
      onlySuccessful: onlySuccessful,
    );

    // Create root instruction set node
    final rootId = const Uuid().v4();
    final rootNode = InstructionSetNode(
      id: rootId,
      name: 'Flat Frames',
      childIds: captureNodes.map((n) => n.id).toList(),
      orderIndex: 0,
      isEnabled: true,
    );

    // Update child nodes with parent reference
    final updatedNodes = <String, SequenceNode>{rootId: rootNode};
    for (int i = 0; i < captureNodes.length; i++) {
      final child = captureNodes[i];
      updatedNodes[child.id] = child.copyWith(parentId: rootId, orderIndex: i);
    }

    // Build description
    final desc =
        description ??
        'Flat frame sequence generated from wizard\n'
            'Filters: ${calibrations.where((c) => !onlySuccessful || c.success).map((c) => c.filter).join(", ")}\n'
            'Frames per filter: $framesPerFilter\n'
            'Generated: ${DateTime.now().toIso8601String()}';

    return Sequence(
      id: const Uuid().v4(),
      name: sequenceName,
      description: desc,
      nodes: updatedNodes,
      rootNodeId: rootId,
      isTemplate: false,
      createdAt: DateTime.now(),
      modifiedAt: DateTime.now(),
    );
  }

  /// Quick calibration with intelligent defaults
  ///
  /// Simplified calibration that uses standard settings for most scenarios
  Future<FlatResult> quickCalibrate({
    required String deviceId,
    required String filter,
    int? gain,
    int? offset,
    double targetAdu = 30000,
    double tolerancePercent = 10.0,
    int binX = 1,
    int binY = 1,
  }) async {
    // Exposure bounds and iteration count come from the
    // service's settings-derived fields rather than hardcoded literals so the
    // user can tune them via the flat wizard global-settings panel.
    return calibrateFilter(
      deviceId: deviceId,
      filter: filter,
      gain: gain,
      offset: offset,
      targetAdu: targetAdu,
      tolerance: tolerancePercent,
      minExposure: quickMinExposure,
      maxExposure: quickMaxExposure,
      maxIterations: defaultMaxIterations,
      binX: binX,
      binY: binY,
    );
  }

  /// Default minimum exposure for [quickCalibrate]. Was hardcoded 0.001s.
  /// Promoted to a service field so user settings can override it.
  final double quickMinExposure;

  /// Default maximum exposure for [quickCalibrate]. Was hardcoded 30.0s.
  final double quickMaxExposure;
}

/// Provider for FlatWizardService.
///
/// Re-watches `flatWizardProvider` so a
/// settings change (min/max exposure, image download timeout, max iterations)
/// rebuilds the service with the new values instead of being silently ignored.
final flatWizardServiceProvider = Provider<FlatWizardService>((ref) {
  final backend = ref.watch(backendProvider.select((b) => b));
  final settings = ref.watch(
    flatWizardProvider.select((s) => s.globalSettings),
  );
  return FlatWizardService.fromSettings(backend, settings);
});
