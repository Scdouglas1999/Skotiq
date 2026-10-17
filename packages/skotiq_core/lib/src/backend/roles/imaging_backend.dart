import 'dart:async';
import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show FitsReadResult, PlateSolveResult;

import '../../models/autofocus_progress.dart' show StarCrop;
import '../../models/backend/backend_types.dart';
import '../../models/imaging/imaging_models.dart' show CapturedImage;
import '../../models/plate_solver.dart'
    show PlateSolverDetection, PlateSolverInfo, PlateSolverPreference;

/// Role interface covering image-data operations.
///
/// What this role owns:
///   * Pixel-buffer transforms: stats, auto-stretch, debayer, star-crop
///     extraction, calibration.
///   * FITS write (raw buffer and "save from last capture" fast-path).
///   * Plate solving against a file (in this codebase plate-solve drives
///     centering, polar align, framing — all imaging consumers).
///   * Polar alignment workflows (start/stop TPPA and all-sky/Sharpcap),
///     which are imaging-loop driven (the camera + plate solver are the
///     core dependencies; mount control is just a follower).
///   * Session image enumeration, thumbnails, full-image download for
///     mobile clients.
///
/// What this role deliberately does NOT own:
///   * Capturing exposures — see [DeviceBackend.cameraStartExposure].
///   * Sequencer image grading / quality config — see [SequencerBackend].
///   * Profile / settings — see [ProfileSettingsBackend].
abstract class ImagingBackend {
  // FITS Save

  /// Save FITS file directly from the last captured image stored server-side.
  /// This eliminates raw pixel data transfer across FFI/network boundaries.
  /// More efficient than saveFitsFile for normal capture workflows.
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  });

  // Plate solving

  /// Solve an image file. [ra] is a solver hint in degrees; [dec] and
  /// [fovDegrees] are also degrees. [timeoutSeconds] bounds the external
  /// solver process on the host.
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  });

  // Plate solver setup
  //
  // Detection / verification / config read+write run against the machine
  // that owns the plate-solver binaries and catalog — i.e. the host wired
  // to the rig. On a remote (phone) client these MUST be routed to the host
  // so the settings page probes the host filesystem and persists solver
  // config on the host, not on the phone. [FfiBackend] runs them locally
  // via the Rust `api_platesolve_*` bridge; [NetworkBackend] forwards them
  // to the host over HTTP.

  /// Probe disk for installed solvers + ASTAP catalog and return a snapshot
  /// the settings UI can render directly.
  Future<PlateSolverDetection> detectPlateSolvers();

  /// Run the given solver binary's `--help` to confirm the install is
  /// healthy, surfacing its version banner.
  Future<PlateSolverInfo> verifyPlateSolver(String executablePath);

  /// Load the persisted plate-solver UX configuration (paths + choice).
  Future<PlateSolverPreference> getPlateSolverConfig();

  /// Persist plate-solver UX configuration. Invalidates the solver-
  /// availability cache so subsequent solves re-probe with the new paths.
  Future<void> setPlateSolverConfig(PlateSolverPreference pref);

  // Image processing

  /// Get star crops from the last captured image for autofocus UI
  Future<List<StarCrop>> getStarCropsFromLastImage(
    String deviceId, {
    int maxCrops = 5,
  });

  /// Calibrate a light frame file on the host filesystem using optional
  /// master dark/flat/bias paths (also host-local when remote).
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  });

  /// Read a FITS file from the host filesystem and return its decoded
  /// dimensions, display data, histogram, stats, and header metadata.
  ///
  /// Host-local: the file lives on the machine wired to the rig. A remote
  /// (phone) client cannot read the host's filesystem directly — it asks the
  /// host for the specific fields it needs (e.g. dimensions via the network
  /// backend's `getFitsDimensions`) instead. The full decode is therefore only
  /// available on the local FFI backend.
  Future<FitsReadResult> readFitsFile({required String filePath});

  /// Auto-stretch a raw mono `u16` image buffer to an 8-bit RGBA display
  /// buffer using the native MAD-based PixInsight screen-transfer-function.
  ///
  /// `data` is `width * height` u16 samples (one luminance plane); the result
  /// is `width * height * 4` RGBA8 bytes.
  ///
  /// Synchronous because the underlying native stretch is a pure CPU transform
  /// over an already-in-memory buffer (matching the sibling
  /// `StackingEngineSeam.autoStretch`), so callers can compute it inline during
  /// a widget build without an await.
  ///
  /// Host-local: the raw pixel buffer never crosses the network boundary —
  /// remote clients receive already-stretched RGBA from the host — so the
  /// network backend rejects this call.
  Uint8List autoStretchImage({
    required int width,
    required int height,
    required List<int> data,
  });

  /// Render the linear FITS at [inputFits] into a viewable, auto-stretched PNG
  /// at [outputPng].
  ///
  /// Runs the FITS -> auto-stretch -> RGBA -> PNG pipeline (see
  /// [StretchPipelineService]) the Session Review workbench uses to preview a
  /// finishing-artifact FITS (background-extraction / deconvolution /
  /// star-reduction passes write a linear FITS with no preview).
  ///
  /// Host-local: both files live on the machine that owns the FITS, so the
  /// network backend cannot run this pipeline against a remote host's disk.
  Future<void> renderFinishingPreview({
    required String inputFits,
    required String outputPng,
  });

  // Polar alignment

  /// Start three-point polar alignment
  ///
  /// This captures 3 images at different mount rotations to calculate
  /// the polar alignment error, then enters adjustment mode where it
  /// continuously updates the error values.
  Future<void> startPolarAlignment({
    required double exposureTime,
    required double stepSize,
    required int binning,
    required bool isNorth,
    required bool manualRotation,
    required bool rotateEast,
    int? gain,
    int? offset,
    double? solveTimeout,
    bool? startFromCurrent,
    double? autoCompleteThreshold,
  });

  /// Stop the polar alignment process
  Future<void> stopPolarAlignment();

  /// Start all-sky (Sharpcap-style) polar alignment.
  ///
  /// Unlike TPPA, this routine works from any direction in the sky. It
  /// captures a single exposure, plate-solves it to anchor a baseline, then
  /// re-solves every `iterationCadenceSecs` to measure drift relative to
  /// that baseline. From the drift signature and the observer's geographic
  /// location it recovers the polar-axis azimuth and altitude error.
  ///
  /// Requires an external plate solver (ASTAP); throws if one is not
  /// installed.
  ///
  /// * `exposureTime` — exposure duration per frame, seconds.
  /// * `solveTimeout` — plate-solve timeout per frame, seconds.
  /// * `binning` — camera binning factor.
  /// * `isNorth` — northern hemisphere observer.
  /// * `acceptanceThresholdArcsec` — auto-complete when total error stays
  ///   below this for 3 seconds (default 30″).
  /// * `iterationCadenceSecs` — re-solve cadence (default 3s).
  /// * `gain`, `offset` — optional camera parameters.
  Future<void> startAllSkyPolarAlignment({
    required double exposureTime,
    required double solveTimeout,
    required int binning,
    required bool isNorth,
    required double acceptanceThresholdArcsec,
    required double iterationCadenceSecs,
    int? gain,
    int? offset,
  });

  // Image Download (for Mobile)

  /// Get list of images for a session
  /// Returns image metadata without full image data
  Future<List<CapturedImage>> getSessionImages(int sessionId);

  /// Get thumbnail preview of an image (JPEG format, ~512x512)
  /// Returns compressed JPEG data for display in UI
  Future<Uint8List> getImageThumbnail(int imageId);

  /// Download full image data with progress tracking
  /// Downloads the full FITS file and saves to localPath
  /// Optionally calls onProgress with download percentage (0.0 to 1.0)
  Future<void> downloadImage(
    int imageId,
    String localPath, {
    void Function(double)? onProgress,
  });
}
