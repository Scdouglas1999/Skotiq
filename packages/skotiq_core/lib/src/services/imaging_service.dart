// ignore_for_file: unused_element

import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as drift;
import 'package:path/path.dart' as path;
import '../models/equipment/equipment_models.dart';
import '../models/imaging/imaging_models.dart';
import '../providers/clock_provider.dart';
import '../providers/equipment_provider.dart';
import '../providers/equipment/device_capability_provider.dart';
import '../providers/imaging_provider.dart';
import '../providers/backend_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/session_provider.dart';
import '../providers/database_provider.dart';
import 'imaging_records_repository.dart';
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
import '../database/daos/images_dao.dart' show ImagesDao;
import '../providers/thumbnail_sidecar_provider.dart';
import '../utils/utc_timestamp.dart';
import 'calibration_service.dart';
import 'notification_service.dart';
import 'logging_service.dart';
import 'science/science_processing_service.dart';
import 'frame_quality_score.dart';
part 'imaging_service/file_paths.dart';
part 'imaging_service/persistence.dart';
part 'imaging_service/quality_processing.dart';
part 'imaging_service/capture_pipeline.dart';
part 'imaging_service/exposure_state.dart';
part 'imaging_service/naming_internals.dart';

/// Service for managing camera capture operations
/// Where a linked client asks the host to write a scratch frame named
/// [fileName]: `Skotiq/scratch` under the host's Documents root (or its first
/// listed root), joined in the host's own path style. The host only writes
/// inside the roots it lists, so a path in the client's temp folder is
/// refused. Null when the host lists no roots.
@visibleForTesting
String? hostScratchFilePath(List<RemoteDirectoryEntry> roots, String fileName) {
  if (roots.isEmpty) return null;
  final root = roots
      .firstWhere((r) => r.name == 'Documents', orElse: () => roots.first)
      .path;
  return hostPathContext(root).join(root, 'Skotiq', 'scratch', fileName);
}

/// The path style of the machine that owns [hostPath]: Windows when it has a
/// drive letter or a backslash, posix otherwise. A linked client must build
/// every path the host will write in this style, never its own.
@visibleForTesting
path.Context hostPathContext(String hostPath) {
  final isWindowsPath =
      hostPath.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(hostPath);
  return path.Context(
    style: isWindowsPath ? path.Style.windows : path.Style.posix,
    current: isWindowsPath ? r'C:\' : '/',
  );
}

class ImagingService {
  final Ref _ref;
  final BackendNotifier _backendOwner;
  final LoggingService _logger;

  // Capture state
  bool _isCapturing = false;
  bool _cancelRequested = false;
  bool _retired = false;
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

  ImagingService(this._ref)
    : _backendOwner = _ref.read(backendProvider.notifier),
      _logger = _ref.read(loggingServiceProvider);

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
  Future<CapturedImageData?> captureUtilityFrame({
    required ExposureSettings settings,
    String? targetName,
  }) {
    return _capture(
      settings: settings,
      targetName: targetName,
      persistFrame: false,
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

  /// Cancel the current exposure
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
    if (_retired) return;
    _retired = true;
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
      !_retired && _backendOwner.isCurrentBackend(backend);

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

  /// Check if currently capturing
  bool get isCapturing => _isCapturing;

  /// All naming-pattern variables this service recognises.
  ///
  /// Keep this in sync with [NamingPattern.availableVariables],
  /// `docs/features/settings.md`, and the documentation in
  /// `native/skotiq_native/imaging/src/naming.rs`. The settings UI
  /// surfaces a shorter subset (`$TARGET, $FILTER, $DATE, $SEQ, $EXPOSURE`),
  /// but the full set is honoured here so that patterns shared between the
  /// Dart and Rust capture paths behave identically.
  static const Set<String> _patternVariables = {
    r'$TARGET',
    r'$FILTER',
    r'$EXPTIME',
    r'$EXPOSURE', // alias documented in settings_screen subtitle + seed_data
    r'$DATE',
    r'$TIME',
    r'$DATETIME',
    r'$FRAMETYPE',
    r'$FRAMENUM',
    r'$SEQ', // alias documented in settings_screen subtitle + defaults
    r'$GAIN',
    r'$OFFSET',
    r'$TEMP',
    r'$BINNING',
    r'$CAMERA',
    r'$TELESCOPE',
    r'$SEQUENCE',
    r'$SESSION',
  };

  /// Regex that finds `$IDENT` tokens (uppercase letters only) in a pattern.
  /// Used by [expandNamingPattern] both to perform substitutions and to
  /// reject unknown variables.
  ///
  /// Underscore is intentionally **excluded** from the character class
  /// because the documented patterns use `_` as a literal separator between
  /// variables (e.g. `$TARGET_$FILTER_$FRAMENUM` ⇒ three tokens joined by
  /// underscores, not one nine-character token). Every variable name in
  /// [_patternVariables] is letters-only, so this is sufficient.
  static final RegExp _patternVarRegex = RegExp(r'\$[A-Z]+');

  static final RegExp _unsafePathComponentChars = RegExp(
    r'[<>:"/\\|?*\x00-\x1F]',
  );

  /// Make equipment- and target-derived values safe as one filename segment.
  /// User-entered names are data, never path syntax: a target named `M31/Ha`
  /// must not create a surprise directory, and `../` must never escape the
  /// configured output root.
  static String _sanitizePathComponent(String value) {
    var sanitized = value.replaceAll(_unsafePathComponentChars, '_').trim();
    sanitized = sanitized.replaceFirst(RegExp(r'^[. _]+'), '');
    sanitized = sanitized.replaceAll(RegExp(r'[. ]+$'), '');
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return '_';
    }
    return sanitized;
  }

  /// Expand `$VARIABLE` tokens in [pattern] using [substitutions].
  ///
  /// Throws an [Exception] if [pattern] references any token that is not in
  /// [_patternVariables]: an unknown `$BANANA` left in the path produces a
  /// filename that looks like it worked and breaks downstream sorting and
  /// searching.
  ///
  /// Exposed for unit testing of the pattern-expansion logic in isolation
  /// from the capture pipeline / provider graph.
  @visibleForTesting
  static String expandNamingPattern(
    String pattern,
    Map<String, String> substitutions,
  ) {
    // Find every $TOKEN in the pattern and validate it up-front so the user
    // gets ONE error listing all unknowns, not one error per failed capture.
    final unknown = <String>{};
    for (final match in _patternVarRegex.allMatches(pattern)) {
      final token = match.group(0)!;
      if (!_patternVariables.contains(token)) {
        unknown.add(token);
      }
    }
    if (unknown.isNotEmpty) {
      final sorted = unknown.toList()..sort();
      throw ValidationException(
        message:
            'Unknown naming-pattern variable${sorted.length == 1 ? '' : 's'} '
            '${sorted.join(', ')} in '
            'pattern "$pattern". Supported variables: '
            '${(_patternVariables.toList()..sort()).join(', ')}.',
        userMessage: 'The naming pattern contains unknown variables',
      );
    }

    // Replace via the regex so prefix overlaps (`$EXPTIME` vs `$EXPOSURE`,
    // `$FRAMENUM` vs `$FRAMETYPE`) cannot be confused with one another.
    final expanded = pattern.replaceAllMapped(_patternVarRegex, (m) {
      final token = m.group(0)!;
      // Safe: we just validated every token above.
      return _sanitizePathComponent(substitutions[token]!);
    });
    if (expanded.contains(r'$')) {
      throw ValidationException(
        message: 'Unrecognized variable syntax in naming pattern "$pattern".',
        userMessage: 'The naming pattern contains an invalid variable',
      );
    }
    return expanded;
  }

  /// Build the absolute file path for a captured image given the resolved
  /// pattern substitutions. Splits the expanded pattern on `/` so that all
  /// segments before the last become subdirectories under [basePath] and the
  /// last segment becomes the filename stem (extension appended).
  ///
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

  /// [pathContext] is the path style of the machine that writes the file
  /// (see [hostPathContext]); it defaults to this machine's, and when given
  /// [basePath] must already be absolute in that style.
  ///
  /// Exposed for unit testing — no filesystem or provider access happens
  /// inside this function.
  @visibleForTesting
  static String buildImageFilePath({
    required String pattern,
    required String basePath,
    required String extension,
    required Map<String, String> substitutions,
    path.Context? pathContext,
  }) {
    final paths = pathContext ?? path.context;
    if (pattern.trim().isEmpty ||
        paths.isAbsolute(pattern) ||
        path.isAbsolute(pattern) ||
        pattern.startsWith('/') ||
        pattern.startsWith(r'\')) {
      throw ValidationException(
        message: 'Naming pattern must be a non-empty relative path: "$pattern"',
        userMessage: 'The naming pattern must be a relative path',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(extension)) {
      throw ValidationException(
        message: 'Invalid capture file extension: "$extension"',
        userMessage: 'The capture file extension is invalid',
      );
    }

    final expanded = expandNamingPattern(pattern, substitutions);

    // Split on '/' (the documented pattern separator). The last segment is
    // the filename stem; earlier segments are subdirectories. If the user's
    // pattern contains no '/' the entire pattern is the filename and the
    // capture lands directly in the base directory.
    final segments = expanded.split('/');
    if (segments.isEmpty) {
      throw ValidationException(
        message: 'Naming pattern expanded to an empty path: "$pattern"',
        userMessage: 'The naming pattern produced an empty file path',
      );
    }
    for (final segment in segments) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains(r'\') ||
          _unsafePathComponentChars.hasMatch(segment)) {
        throw ValidationException(
          message:
              'Unsafe path segment "$segment" in naming pattern "$pattern"',
          userMessage: 'The naming pattern contains an unsafe path segment',
        );
      }
    }
    final fileNameStem = segments.removeLast();
    final fileName = '$fileNameStem.$extension';
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

  /// Build the canonical substitution map for `$DATE`, `$TIME`, etc. given
  /// only the values that don't require provider access (camera state, mount
  /// state). Useful for unit tests that want to verify the UTC date/time
  /// conventions without spinning up a `ProviderContainer`. The full
  /// provider-aware map lives in [_buildPatternSubstitutions].
  @visibleForTesting
  static Map<String, String> buildTimestampSubstitutions({
    required ExposureSettings exposureSettings,
    String? targetName,
    required int frameNumber,
    required DateTime timestamp,
    String camera = 'Camera',
    String telescope = 'Telescope',
    String tempStr = '0C',
  }) {
    final utcTs = timestamp.toUtc();
    final iso = utcTs.toIso8601String();
    final dateStr = iso.substring(0, 10);
    final timeStr = iso.substring(11, 19).replaceAll(':', '-');
    final frameNumStr = frameNumber.toString().padLeft(4, '0');
    final exposureStr = exposureSettings.exposureTime.toStringAsFixed(1);

    return {
      r'$TARGET': targetName ?? 'Unknown',
      r'$FILTER': exposureSettings.filter ?? 'NoFilter',
      r'$EXPTIME': exposureStr,
      r'$EXPOSURE': exposureStr,
      r'$DATE': dateStr,
      r'$TIME': timeStr,
      r'$DATETIME': '${dateStr}_$timeStr',
      r'$FRAMETYPE': exposureSettings.frameType.name,
      r'$FRAMENUM': frameNumStr,
      r'$SEQ': frameNumStr,
      r'$GAIN': exposureSettings.gain.toString(),
      r'$OFFSET': exposureSettings.offset.toString(),
      r'$TEMP': tempStr,
      r'$BINNING': '${exposureSettings.binningX}x${exposureSettings.binningY}',
      r'$CAMERA': camera,
      r'$TELESCOPE': telescope,
      // The sequence this frame belongs to, matching `$SEQUENCE` in the Rust
      // FilenameGenerator (naming.rs), whose no-sequence value is the literal
      // "Sequence". Nothing on this path — manual Snapshot, Loop, plate-solve
      // frame — belongs to a sequence, so substituting the TARGET here labelled
      // a plain target folder as a sequence and made the same pattern produce
      // two different trees depending on which capture path wrote the frame.
      r'$SEQUENCE': 'Sequence',
      r'$SESSION': dateStr.replaceAll('-', ''),
    };
  }
}

/// Provider for the imaging service
final imagingServiceProvider = Provider<ImagingService>((ref) {
  // Capture is backend-owned. Rebuild the service when the active host
  // changes so callers can use service identity as an authority boundary.
  ref.watch(backendProvider);
  final service = ImagingService(ref);
  ref.onDispose(service.retire);
  return service;
});

/// Provider for the current displayed image
final currentImageProvider = StateProvider<CapturedImageData?>((ref) => null);

/// Whether the currently displayed image has been auto-calibrated.
///
/// Derived from `currentImageProvider.filePath`: the calibration service
/// writes calibrated frames with a `_cal.fits` suffix, and the imaging
/// service swaps the file path on the captured image data once the
/// calibration step succeeds (see `ImagingService.captureImage` —
/// auto-calibration block). When calibration fails or isn't enabled the
/// path stays at the original `.fits`, so the badge reflects only frames that
/// were actually calibrated.
final currentImageIsCalibratedProvider = Provider<bool>((ref) {
  final image = ref.watch(currentImageProvider);
  final path = image?.filePath;
  if (path == null || path.isEmpty) {
    return false;
  }
  // The calibration service produces files ending in `_cal.fits` (or
  // `_cal.fit`). We match either casing on the suffix; the rest of the
  // pipeline normalises paths but the suffix itself is stable.
  final lower = path.toLowerCase();
  return lower.endsWith('_cal.fits') || lower.endsWith('_cal.fit');
});

/// Live preview histogram: uses host raw pixels when [CapturedImageData.hasRawReady],
/// otherwise the JPEG preview histogram bundled with the capture.
final previewDisplayHistogramProvider = Provider<List<int>?>((ref) {
  final image = ref.watch(currentImageProvider);
  if (image == null) {
    return null;
  }
  if (image.hasRawReady && image.rawU16 != null) {
    return histogram256FromRawU16(image.rawU16!);
  }
  return image.histogram;
});

/// Build 256-bin histogram from 16-bit mono raw (high byte per pixel).
List<int> histogram256FromRawU16(Uint16List raw) {
  final bins = List<int>.filled(256, 0);
  for (var i = 0; i < raw.length; i++) {
    bins[raw[i] >> 8]++;
  }
  return bins;
}

/// Provider for exposure progress
final exposureProgressProvider =
    StateNotifierProvider<ExposureProgressNotifier, ExposureProgress>((ref) {
      return ExposureProgressNotifier();
    });

/// Exposure progress notifier
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

  void reset() {
    state = ExposureProgress.idle();
  }
}
