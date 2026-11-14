// ignore_for_file: unused_element

import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as drift;
import 'package:path/path.dart' as path;
import '../errors/error_text.dart';
import '../models/equipment/equipment_models.dart';
import '../models/imaging/imaging_models.dart';
import '../models/imaging/naming_pattern.dart';
import '../providers/clock_provider.dart';
import '../providers/equipment_provider.dart';
import '../providers/capability_provider.dart' show cameraSensitivityProvider;
import '../providers/equipment/device_capability_provider.dart';
import '../providers/imaging_provider.dart';
import '../providers/async_scope.dart';
import '../providers/backend_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/session_provider.dart';
import 'local_imaging_records.dart';
import '../providers/ui_notification_provider.dart';
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../backend/skotiq_exception.dart'
    show
        ConnectionException,
        DeviceBusyException,
        ImagingException,
        SkotiqException,
        ValidationException;
import 'capture_preview_loader.dart';
import '../database/database.dart' show CapturedImagesCompanion;
import '../utils/host_paths.dart';
import '../utils/utc_timestamp.dart';
import 'frame_identity.dart';
import 'logging_service.dart';
import 'frame_quality_score.dart';
import '../backend/roles/host_data/host_files.dart';
import '../backend/roles/host_data/host_imaging_records.dart';
import '../models/backend/backend_types.dart';
import '../settings/app_settings_state.g.dart';
import '../providers/calibration_service_providers.dart';
import '../providers/capture_preview_loader_provider.dart';
import '../providers/logging_service_provider.dart';
import '../providers/notification_service_provider.dart';
import '../providers/science/science_processing_service_provider.dart';
part 'imaging_service/file_paths.dart';
part 'imaging_service/persistence.dart';
part 'imaging_service/quality_processing.dart';
part 'imaging_service/capture_pipeline.dart';
part 'imaging_service/exposure_state.dart';
part 'imaging_service/naming_internals.dart';

/// Service for managing camera capture operations
class ImagingService {
  final Ref _ref;
  final AsyncScope<SkotiqBackend> _host;
  final LoggingService _logger;

  bool _isCapturing = false;
  bool _cancelRequested = false;
  int _frameNumber = 0;

  /// Keeper paths this service has handed out on a linked host, in
  /// host-path-key form, so two quick saves never pick the same name before
  /// the host has recorded the first.
  final Set<String> _hostReservedKeeperPaths = {};

  // Pending exposure completer so cancelExposure() can interrupt an
  // in-flight exposure instead of only setting the loop-break flag: resolving
  // it false sends captureImage down its cancel branch, which aborts the
  // sensor. Cleared in captureImage's finally.
  Completer<bool>? _activeExposureCompleter;

  /// Backend/device captured at exposure admission. Abort must target this
  /// exact camera even if the active host or equipment selection changes while
  /// the driver call is blocked.
  SkotiqBackend? _activeCaptureBackend;
  String? _activeCaptureDeviceId;
  Future<void>? _activeAbortFuture;

  /// True between "this capture told the app an exposure is running" and
  /// "this capture took that back". `cameraStateProvider.isExposing` and
  /// `exposureProgressProvider` are shared with the sequencer and the remote
  /// mirror, so the release must fire exactly once and only from the capture
  /// that armed them — see [_releaseSharedExposureState].
  bool _ownsSharedExposureState = false;

  /// The notifiers the in-flight capture armed, held on the instance so
  /// [retire] can put them back without touching its own `Ref`, which is
  /// already being disposed by the time [retire] runs.
  CameraStateNotifier? _activeCameraNotifier;
  ExposureProgressNotifier? _activeProgressNotifier;

  static const _imageDownloadTimeout = Duration(seconds: 60);

  /// How far [_nextKeeperFrameNumber] will walk past an occupied sequence
  /// number before giving up and letting [uniqueFilePath] handle the
  /// collision. One `stat` per step, so a full night of frames costs well
  /// under a millisecond; the ceiling only exists so a pathological folder
  /// cannot stall a capture.
  static const int _keeperProbeLimit = 100000;

  /// [hostFiles] and [hostRecords] are the linked host's, or null where the
  /// camera's frames are written and recorded by this process.
  ImagingService(
    this._ref, {
    HostFiles? hostFiles,
    HostImagingRecords? hostRecords,
  }) : _host = _ref.providerBackendScope(),
       _logger = _ref.read(loggingServiceProvider),
       _hostFiles = hostFiles,
       _hostRecords = hostRecords;

  final HostFiles? _hostFiles;
  final HostImagingRecords? _hostRecords;

  /// Start a single exposure and KEEP the frame: it is written to the
  /// operator's configured image folder under the naming pattern and indexed
  /// in `captured_images`.
  ///
  /// Live view goes through [startLoopCapture] instead, which routes frames to
  /// a scratch path. This entry point stays keeper-only so a subclass that
  /// stubs it (tests, remote shims) cannot accidentally change where an
  /// acquisition frame lands.
  Future<CapturedImageData?> captureImage({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    // Thumbnail — producing-instruction provenance. When the
    // imaging service is called from a sequencer-tagged path (e.g.
    // future plugin-node captures), the caller can pass the node id
    // here so the persisted row is queryable by
    // [ImagesDao.watchImagesByProducingNode]. Ad-hoc captures from the
    // Imaging tab simply leave this `null`.
    String? producingNodeId,
    String? producingRunId,
  }) {
    return _capture(
      settings: settings,
      targetName: targetName,
      frameNumber: frameNumber,
      producingNodeId: producingNodeId,
      producingRunId: producingRunId,
      persistFrame: true,
      keepsCameraFile: true,
    );
  }

  /// Start a single exposure that is a MEANS, not a product: a plate-solve
  /// frame for centering/verification, a focus check, an alignment shot.
  ///
  /// It lands on the same reused scratch path [startLoopCapture] uses, so the
  /// solver, annotation and the preview loader keep working, but it never
  /// enters the operator's light-frame folder, `captured_images`, or the
  /// session's frame and integration totals. Centering runs up to
  /// [CenteringConfig.maxIterations] of these per target; as keepers they
  /// inflated the night's frame count with images nobody will ever stack.
  ///
  /// [purpose] labels the frame on screen ("Plate solve", "Centering ·
  /// attempt 2 of 5"); a framing snapshot keeps [FramePurpose.capture].
  Future<CapturedImageData?> captureUtilityFrame({
    required ExposureSettings settings,
    String? targetName,
    FramePurpose purpose = FramePurpose.capture,
    int? purposeStep,
    int? purposeSteps,
  }) {
    return _capture(
      settings: settings,
      targetName: targetName,
      persistFrame: false,
      keepsCameraFile: false,
      purpose: purpose,
      purposeStep: purposeStep,
      purposeSteps: purposeSteps,
    );
  }

  /// Stamp [settings] with the filter the connected wheel is actually parked
  /// on, so the FITS `FILTER` card, the `$FILTER` filename token and the
  /// `captured_images.filter` column all describe the same physical glass.
  ///
  /// The live wheel wins over [ExposureSettings.filter] whenever it can name
  /// its current slot: the settings copy is a UI mirror that any call site can
  /// forget to update (and one did), whereas the wheel position is the state
  /// the photons went through. With no wheel connected — or a wheel that
  /// cannot name its slot — the caller-supplied value is kept untouched, which
  /// is what a filter-less imaging train and the sequencer's explicit
  /// per-instruction filter both need.
  @visibleForTesting
  ExposureSettings withLiveFilterForTest(ExposureSettings settings) =>
      _withLiveFilter(settings);

  /// Filesystem-safe key for [deviceId], used to give each camera its own
  /// live-view scratch file so two cameras looping at once cannot overwrite
  /// each other's frame mid-read.
  static String _scratchKey(String deviceId) =>
      deviceId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  /// Start looping capture
  ///
  /// Includes a circuit breaker: after [maxConsecutiveErrors] consecutive
  /// failures the loop aborts to avoid hammering a broken device endlessly.
  ///
  /// [saveFrames] defaults to FALSE because Loop is a live-view/framing mode,
  /// not an acquisition run. Callers that need persisted frames opt in.
  Future<void> startLoopCapture({
    required ExposureSettings settings,
    String? targetName,
    int? maxFrames,
    int maxConsecutiveErrors = 10,
    bool saveFrames = false,
    void Function(CapturedImageData)? onImageCaptured,
    void Function(String)? onError,
  }) async {
    int frameNum = 0;
    int consecutiveErrors = 0;

    // A new run is not the cancelled one.
    //
    // `cancelExposure()` latches `_cancelRequested`, and the only place that
    // clears it is `_capture` — which this loop reaches only AFTER testing the
    // flag below. So a Stop, or an Abort taken mid-exposure, left the latch set
    // and the NEXT press of Loop started and ended without ever exposing: a
    // silently dead button, with no error and nothing in the log.
    //
    // This already bit the Imaging screen, whose Stop Loop calls
    // `cancelExposure()`, and moving the Dashboard capture card onto this entry
    // point inherited it.
    _cancelRequested = false;

    while (!_cancelRequested && (maxFrames == null || frameNum < maxFrames)) {
      frameNum++;
      try {
        final image = await _capture(
          settings: settings,
          targetName: targetName,
          // A saving loop is an acquisition run, so its frames continue the
          // session's keeper numbering. Restarting at 1 every run made the
          // second Loop of the night rewrite `..._0001` over the first one's
          // numbers — survivable only because uniqueFilePath appends
          // `_001`, which is not a sequence number the operator asked for.
          // A live-view run keeps its own 1..N index; it only feeds the
          // progress ring.
          frameNumber: saveFrames ? null : frameNum,
          persistFrame: saveFrames,
          // Loop frames are framing and focusing aids, kept or not: never
          // the camera's raw file.
          keepsCameraFile: false,
        );

        if (image != null) {
          consecutiveErrors = 0;
          onImageCaptured?.call(image);
        }
      } catch (e) {
        consecutiveErrors++;
        onError?.call(e.toString());

        // A non-recoverable structured error (notably a FITS write failure)
        // must stop immediately. Retrying ten more exposures would only lose
        // more frames to the same full/unwritable destination.
        if (e is SkotiqException && !e.isRecoverable) {
          _logger.error(
            'Loop capture stopped after non-recoverable error: $e',
            source: 'ImagingService',
          );
          break;
        }

        if (consecutiveErrors >= maxConsecutiveErrors) {
          final msg =
              'Loop capture aborted after $consecutiveErrors consecutive errors. '
              'Last error: $e';
          _logger.error(msg, source: 'ImagingService');
          onError?.call(msg);
          break;
        }
      }

      // Small delay between frames
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  void cancelExposure() {
    _cancelRequested = true;
    // Interrupt an in-flight single capture. Setting the flag alone only
    // breaks a loop between frames; a lone exposure blocks waiting on this
    // completer, so resolve it false — captureImage's cancel branch then
    // aborts the sensor exactly once.
    final completer = _activeExposureCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }

    // cameraStartExposure is blocking on several native drivers and on the
    // remote host route. Waiting for captureImage to reach its completer branch
    // would therefore send Abort only after the exposure had already ended.
    // Dispatch against the backend/device captured at admission immediately.
    final abort = _abortActiveExposure();
    unawaited(
      abort.catchError((Object error, StackTrace stackTrace) {
        _logger.warning(
          'Immediate camera abort failed: $error\n$stackTrace',
          source: 'ImagingService',
        );
      }),
    );
  }

  /// Retire this service when its backend dependency changes. The old
  /// instance may still have asynchronous driver work unwinding, but it must
  /// never publish into the replacement host's provider graph.
  void retire() {
    _cancelRequested = true;

    final completer = _activeExposureCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }

    unawaited(_abortActiveExposure().catchError((_) {}));

    // Promptly, not when the abandoned exposure's own unwinding gets around to
    // it: a 300 s sub would otherwise leave the UI narrating a dead frame for
    // five more minutes. Uses the notifiers captured at exposure start because
    // this runs inside `ref.onDispose`, where this service's own `Ref` is gone.
    _releaseSharedExposureState();
  }

  bool _hasBackendAuthority(SkotiqBackend backend) =>
      identical(backend, _host.value) && _host.isCurrent;

  /// Keys under which an imaging event may carry the originating camera id.
  /// Mirrors `FlatWizardService._deviceIdKeys` — the two services listen to the
  /// same stream and must agree on how a frame is attributed to a camera.
  static const List<String> _cameraIdKeys = [
    'deviceId',
    'device_id',
    'cameraId',
    'camera_id',
  ];

  /// Whether [event] belongs to the exposure we started on [deviceId].
  ///
  /// FFI-originated events do NOT carry a camera id (the native side drives a
  /// single active camera), so absence means "accept" — the event is scoped to
  /// the operation. When an id IS present it must be ours: on a dual-camera rig
  /// the guide camera publishes onto this same stream, and its completion used
  /// to settle the main camera's wait, sending the download in mid-exposure.
  static bool _eventNamesCamera(SkotiqEvent event, String deviceId) {
    for (final key in _cameraIdKeys) {
      final raw = event.data[key];
      if (raw != null &&
          raw.toString().isNotEmpty &&
          raw.toString() != deviceId) {
        return false;
      }
    }
    return true;
  }

  bool get isCapturing => _isCapturing;

  /// Throws the [ValidationException] that fails a capture when [pattern]
  /// cannot name a frame.
  static void _requireUsablePattern(String pattern) {
    final problem = NamingPattern.problem(pattern);
    if (problem != null) {
      throw ValidationException(
        message: 'Naming pattern "$pattern": $problem',
        userMessage: problem,
      );
    }
  }

  /// [desiredPath], or the first `<name>_NNN<ext>` beside it that [exists]
  /// says is free. [paths] is the path style of the machine that owns it.
  @visibleForTesting
  static Future<String> uniqueFilePath(
    String desiredPath,
    path.Context paths,
    Future<bool> Function(String candidate) exists,
  ) async {
    var candidate = desiredPath;
    var suffix = 1;
    final directory = paths.dirname(desiredPath);
    final baseName = paths.basenameWithoutExtension(desiredPath);
    final extension = paths.extension(desiredPath);
    while (await exists(candidate)) {
      candidate = paths.join(
        directory,
        '${baseName}_${suffix.toString().padLeft(3, '0')}$extension',
      );
      suffix++;
    }
    return candidate;
  }

  /// The absolute path [pattern] gives a frame of [values] under
  /// [basePath]: every segment before the last is a folder, the last is the
  /// filename stem, [extension] is appended.
  ///
  /// [pathContext] is the path style of the machine that writes the file
  /// (see [hostPathContext]); it defaults to this machine's, and when given
  /// [basePath] must already be absolute in that style.
  @visibleForTesting
  static String buildImageFilePath({
    required String pattern,
    required String basePath,
    required String extension,
    required Map<NamingToken, String> values,
    path.Context? pathContext,
  }) {
    final paths = pathContext ?? path.context;
    _requireUsablePattern(pattern);
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(extension)) {
      throw ValidationException(
        message: 'Invalid capture file extension: "$extension"',
        userMessage: 'The capture file extension is invalid',
      );
    }
    final segments = NamingPattern.segments(pattern, values);
    final fileName = '${segments.removeLast()}.$extension';
    // Another machine's base path cannot be resolved against this process's
    // working directory: a relative one is refused rather than guessed.
    if (pathContext != null && !paths.isAbsolute(basePath)) {
      throw ValidationException(
        message: 'Host image output path is not absolute: "$basePath"',
        userMessage: 'The imaging host has no usable image output folder',
      );
    }
    final normalizedBase = paths.normalize(paths.absolute(basePath));
    final candidate = paths.normalize(
      paths.joinAll([normalizedBase, ...segments, fileName]),
    );
    if (!paths.isWithin(normalizedBase, candidate)) {
      throw ValidationException(
        message: 'Capture path escaped output directory: "$candidate"',
        userMessage: 'The naming pattern points outside the output folder',
      );
    }
    return candidate;
  }

  /// Where a kept frame of [exposureSettings] taken now goes in [folder] (a
  /// folder of the imaging host): named by the Settings naming pattern as a
  /// manual capture is, at the next frame number not on disk, and never a
  /// name that is taken or already handed out. For a screen that keeps frames
  /// in its own folder (the Flat Wizard).
  Future<String> keeperFilePath({
    required String folder,
    required ExposureSettings exposureSettings,
    String? targetName,
  }) async {
    final frameNumber = await _nextKeeperFrameNumber(
      basePath: folder,
      exposureSettings: exposureSettings,
      targetName: targetName,
    );
    return _generateImageFilePath(
      basePath: folder,
      exposureSettings: exposureSettings,
      targetName: targetName,
      frameNumber: frameNumber,
      // The instant the frame number was probed with.
      timestamp: _ref.read(clockProvider).nowUtc(),
    );
  }

  /// The Settings naming [pattern] as the save template (`save_to`) of a
  /// run's frames of [step] ([NamingPattern.runTemplate]). The same pattern
  /// names a manual capture and a sequence frame alike.
  ///
  /// Throws the [ValidationException] a manual capture with [pattern] would,
  /// so a pattern that cannot name a frame stops the run before it starts.
  static String runFrameSaveTemplate(String pattern, NamingStep step) {
    _requireUsablePattern(pattern);
    return NamingPattern.runTemplate(pattern, step);
  }

  /// The naming values of a frame of [exposureSettings] taken by hand at
  /// [timestamp], outside any sequence.
  @visibleForTesting
  static Map<NamingToken, String> manualFrameValues({
    required ExposureSettings exposureSettings,
    String? targetName,
    required int frameNumber,
    required DateTime timestamp,
    String? camera,
    String? telescope,
    double? sensorTempC,
  }) => NamingPattern.values(
    NamingStep(
      frameType: exposureSettings.frameType,
      gain: exposureSettings.gain,
      offset: exposureSettings.offset,
      binX: exposureSettings.binningX,
      binY: exposureSettings.binningY,
      camera: camera,
      telescope: telescope,
      session: timestamp,
    ),
    NamingFrame(
      target: targetName,
      filter: exposureSettings.filter,
      exposureSeconds: exposureSettings.exposureTime,
      number: frameNumber,
      takenAt: timestamp,
      sensorTempC: sensorTempC,
    ),
  );
}

final currentImageProvider = StateProvider<CapturedImageData?>((ref) => null);

/// Exact 256-bin raw histogram, yielding between bounded pixel batches.
///
/// Scanning a full sensor in a widget's build blocks the UI. Keeping batches
/// here avoids both that stall and an isolate's copy of the raw buffer.
/// Returns null when the consumer no longer needs this frame.
Future<List<int>?> histogram256FromRawU16(
  Uint16List raw, {
  bool Function()? isCancelled,
}) async {
  const batchSize = 64 * 1024;
  final bins = List<int>.filled(256, 0);
  for (var start = 0; start < raw.length; start += batchSize) {
    await Future<void>.delayed(Duration.zero);
    if (isCancelled?.call() ?? false) return null;
    final end = start + batchSize < raw.length ? start + batchSize : raw.length;
    for (var i = start; i < end; i++) {
      bins[raw[i] >> 8]++;
    }
  }
  return bins;
}

final exposureProgressProvider =
    StateNotifierProvider<ExposureProgressNotifier, ExposureProgress>((ref) {
      return ExposureProgressNotifier();
    });

class ExposureProgressNotifier extends StateNotifier<ExposureProgress> {
  ExposureProgressNotifier() : super(ExposureProgress.idle());

  void startExposure(double totalTime, int frameNumber, int? totalFrames) {
    state = ExposureProgress(
      elapsed: 0,
      remaining: totalTime,
      percent: 0,
      frameNumber: frameNumber,
      totalFrames: totalFrames,
      isDownloading: false,
    );
  }

  void updateProgress(double elapsed, double remaining, double percent) {
    state = ExposureProgress(
      elapsed: elapsed,
      remaining: remaining,
      percent: percent,
      frameNumber: state.frameNumber,
      totalFrames: state.totalFrames,
      isDownloading: false,
    );
  }

  void startDownload() {
    state = ExposureProgress(
      elapsed: state.elapsed,
      remaining: 0,
      percent: 100,
      frameNumber: state.frameNumber,
      totalFrames: state.totalFrames,
      isDownloading: true,
    );
  }

  /// Shows the countdown another process reported.
  void show(ExposureProgress progress) => state = progress;

  void reset() {
    state = ExposureProgress.idle();
  }
}
