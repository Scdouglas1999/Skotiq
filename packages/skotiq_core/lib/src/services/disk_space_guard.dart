import 'dart:async';

import '../models/backend/device_capabilities.dart';
import '../models/sequence/sequence_models.dart';
import 'disk_space_service.dart';
import 'logging_service.dart';

/// Default thresholds for disk-space watchdog.
///
/// Picked so a typical multi-hour DSLR/CMOS run can be paused with a few frames
/// of headroom before the OS itself complains:
/// - Warning at 10 GB free: enough for ~100-200 standard frames at 50-100 MB.
/// - Abort at 2 GB free: leaves room for the OS swap/log files to breathe
///   and for the sequencer to finish writing the in-flight frame cleanly.
const int kDefaultDiskWarningGb = 10;
const int kDefaultDiskAbortGb = 2;

/// Pre-flight severity returned by [DiskSpaceProjection].
///
/// `blocking` should hard-stop the sequence; `warning` should require an
/// explicit user override; `info` is informational only.
enum DiskSpaceSeverity { info, warning, blocking }

/// Pre-flight result for a sequence: free space vs. projected size.
///
/// Computed by [DiskSpaceGuardService.projectSequence]; mirrors the three
/// severity bands described in the F3 spec:
/// - info     if projected < 60% of free
/// - warning  if projected > 60% of free
/// - blocking if projected > free - 2 GB safety margin
class DiskSpaceProjection {
  final int freeBytes;
  final int totalBytes;
  final int projectedBytes;
  final DiskSpaceSeverity severity;
  final String headline;
  final String detail;

  const DiskSpaceProjection({
    required this.freeBytes,
    required this.totalBytes,
    required this.projectedBytes,
    required this.severity,
    required this.headline,
    required this.detail,
  });

  int get bytesAfterRun => freeBytes - projectedBytes;
}

/// Live watchdog event emitted while a session is running.
class DiskSpaceWatchdogEvent {
  final DiskSpaceInfo snapshot;
  final DiskSpaceSeverity severity;
  final String message;

  const DiskSpaceWatchdogEvent({
    required this.snapshot,
    required this.severity,
    required this.message,
  });
}

/// 2 GB hard safety margin: writes that overrun this leave the OS without
/// scratch space for journals, swap, and log rotation — and in practice
/// any further capture will fail mid-frame. Used by both the pre-flight
/// projection and the mid-run abort threshold.
const int kSafetyMarginBytes = 2 * 1024 * 1024 * 1024;

/// Cooperative service that combines [DiskSpaceService] queries with
/// projection math and a periodic watchdog.
///
/// The watchdog is implemented purely in Dart: no FRB churn, and the
/// Rust sequencer keeps a single source of truth for the run. Watching from
/// the Dart side is enough — the executor's stop()/pause() path is exposed
/// in Dart and reaches the native runtime through the existing backend.
class DiskSpaceGuardService {
  final DiskSpaceService _diskService;
  final LoggingService? _logger;

  Timer? _watchdogTimer;
  StreamController<DiskSpaceWatchdogEvent>? _eventsController;
  bool _hasEmittedWarning = false;
  bool _hasEmittedAbort = false;
  bool _watchdogPollInFlight = false;
  int _watchdogGeneration = 0;

  DiskSpaceGuardService({
    required DiskSpaceService diskService,
    LoggingService? logger,
  }) : _diskService = diskService,
       _logger = logger;

  /// Compute the per-frame byte cost for an [ExposureNode] given camera
  /// [capabilities]. Returns null when capabilities are missing (caller
  /// should treat that as "cannot project; warn the user").
  ///
  /// Sizing model:
  ///   bytes_per_frame = (width / binX) * (height / binY) * bytes_per_pixel
  ///   bytes_per_pixel = ceil(bit_depth / 8) * channels
  ///
  /// Channels: mono = 1; one-shot-color sensors save the raw Bayer mosaic
  /// (also 1 channel at the sensor level — debayering happens later) so we
  /// treat color cameras the same as mono for storage projection. FITS/XISF
  /// headers add ~40 KB which is rounded into a 64 KB per-frame overhead.
  static int? projectFrameBytes(
    ExposureNode node,
    CameraCapabilities? capabilities,
  ) {
    if (capabilities == null) return null;
    final maxWidth = capabilities.maxWidth;
    final maxHeight = capabilities.maxHeight;
    if (maxWidth <= 0 || maxHeight <= 0) return null;

    final binX = node.binning.xFactor;
    final binY = node.binning.yFactor;
    final width = (maxWidth / binX).floor();
    final height = (maxHeight / binY).floor();
    final bytesPerPixel = ((capabilities.bitDepth + 7) ~/ 8);
    if (bytesPerPixel <= 0) return null;
    // 64 KB header overhead per frame for FITS/XISF metadata.
    return width * height * bytesPerPixel + 65536;
  }

  /// Total projected bytes for all enabled exposure nodes in a sequence,
  /// given [capabilities]. Returns null if any enabled exposure node lacks a
  /// usable per-frame cost (the caller should treat that as "unknown" and
  /// surface a warning rather than guessing).
  static int? projectSequenceBytes(
    Sequence sequence,
    CameraCapabilities? capabilities,
  ) {
    if (capabilities == null) return null;
    int total = 0;
    for (final node in sequence.nodes.values) {
      if (node is! ExposureNode) continue;
      if (!node.isEnabled) continue;
      final perFrame = projectFrameBytes(node, capabilities);
      if (perFrame == null) return null;
      total += perFrame * node.count;
    }
    return total;
  }

  /// Run the pre-flight projection. Both [capturePath] and [sequence] must
  /// be supplied; [capabilities] is optional but recommended.
  ///
  /// Propagates [DiskSpaceException] when the disk query fails. Callers
  /// should NOT silently catch and substitute zero — surface the error.
  Future<DiskSpaceProjection> projectSequence({
    required String capturePath,
    required Sequence sequence,
    required CameraCapabilities? capabilities,
  }) async {
    final snapshot = await _diskService.query(capturePath);
    final projected = projectSequenceBytes(sequence, capabilities);

    if (projected == null) {
      // Camera capability missing: we can't project size but we can still
      // report free space. Mark as info so the user is aware.
      return DiskSpaceProjection(
        freeBytes: snapshot.freeBytes,
        totalBytes: snapshot.totalBytes,
        projectedBytes: 0,
        severity: DiskSpaceSeverity.info,
        headline:
            '${_gb(snapshot.freeBytes)} GB free on ${snapshot.path}; projected size unknown',
        detail:
            'Connect a camera so sequence size can be projected against free space.',
      );
    }

    final free = snapshot.freeBytes;
    final afterRun = free - projected;

    if (afterRun < kSafetyMarginBytes) {
      return DiskSpaceProjection(
        freeBytes: free,
        totalBytes: snapshot.totalBytes,
        projectedBytes: projected,
        severity: DiskSpaceSeverity.blocking,
        headline:
            'Run cannot complete: would leave only ${_gb(afterRun)} GB free '
            '(${_gb(projected)} GB needed, ${_gb(free)} GB available)',
        detail:
            'The capture directory does not have enough free space to finish '
            'this sequence with a 2 GB safety margin. Free up space, choose a '
            'different drive, or shorten the run before starting.',
      );
    }

    if (projected > free * 0.6) {
      return DiskSpaceProjection(
        freeBytes: free,
        totalBytes: snapshot.totalBytes,
        projectedBytes: projected,
        severity: DiskSpaceSeverity.warning,
        headline:
            'Run will leave ${_gb(afterRun)} GB free '
            '(needs ${_gb(projected)} of ${_gb(free)} GB available)',
        detail:
            'This sequence will consume more than 60% of the available space. '
            'Consider archiving recent images before starting.',
      );
    }

    return DiskSpaceProjection(
      freeBytes: free,
      totalBytes: snapshot.totalBytes,
      projectedBytes: projected,
      severity: DiskSpaceSeverity.info,
      headline:
          'You have ${_gb(free)} GB free; this run will consume ~${_gb(projected)} GB',
      detail:
          '${_gb(afterRun)} GB will remain free after the sequence finishes.',
    );
  }

  /// Sample the disk once at a fixed point in time (e.g. for the Storage
  /// tile). Propagates [DiskSpaceException].
  Future<DiskSpaceInfo> sample(String capturePath) =>
      _diskService.query(capturePath);

  /// Whether a watchdog is currently active.
  bool get isRunning => _watchdogTimer?.isActive == true;

  /// Stream of watchdog events. Closed when [stop] is called.
  Stream<DiskSpaceWatchdogEvent> get events {
    _eventsController ??= StreamController<DiskSpaceWatchdogEvent>.broadcast();
    return _eventsController!.stream;
  }

  /// Start the watchdog. Polls every [interval] (default 30 s) and emits a
  /// [DiskSpaceWatchdogEvent] when free space drops below either threshold.
  /// Re-arming hysteresis: once a severity has fired, we don't fire the same
  /// severity again until free space recovers above the next threshold. This
  /// keeps the UI from spamming the alert log mid-run.
  void start({
    required String capturePath,
    int warningBytes = kDefaultDiskWarningGb * 1024 * 1024 * 1024,
    int abortBytes = kDefaultDiskAbortGb * 1024 * 1024 * 1024,
    Duration interval = const Duration(seconds: 30),
  }) {
    stop();
    _eventsController ??= StreamController<DiskSpaceWatchdogEvent>.broadcast();
    _hasEmittedWarning = false;
    _hasEmittedAbort = false;
    final generation = _watchdogGeneration;

    Future<void> poll() async {
      if (generation != _watchdogGeneration || _watchdogPollInFlight) return;
      _watchdogPollInFlight = true;
      try {
        final snapshot = await _diskService.query(capturePath);
        if (generation != _watchdogGeneration) return;
        if (snapshot.freeBytes < abortBytes && !_hasEmittedAbort) {
          _hasEmittedAbort = true;
          _emit(
            DiskSpaceWatchdogEvent(
              snapshot: snapshot,
              severity: DiskSpaceSeverity.blocking,
              message:
                  'Critical: only ${_gb(snapshot.freeBytes)} GB free on ${snapshot.path}. '
                  'Pause and free up space before continuing.',
            ),
          );
        } else if (snapshot.freeBytes < warningBytes && !_hasEmittedWarning) {
          _hasEmittedWarning = true;
          _emit(
            DiskSpaceWatchdogEvent(
              snapshot: snapshot,
              severity: DiskSpaceSeverity.warning,
              message:
                  'Low disk space: ${_gb(snapshot.freeBytes)} GB free on ${snapshot.path}. '
                  'Consider stopping after the current target.',
            ),
          );
        }

        // Reset hysteresis if space comes back (e.g. user archived mid-run).
        if (snapshot.freeBytes >= warningBytes * 1.1) {
          _hasEmittedWarning = false;
        }
        if (snapshot.freeBytes >= abortBytes * 2) {
          _hasEmittedAbort = false;
        }
      } catch (e, stack) {
        if (generation != _watchdogGeneration) return;
        _logger?.warning(
          'Disk-space watchdog poll failed: $e\n$stack',
          source: 'DiskSpaceGuardService',
        );
        // We propagate failure as a watchdog event so the UI can show the user
        // that monitoring is degraded. We do NOT silently continue — silent
        // failure here would defeat the whole point of the watchdog.
        _emit(
          DiskSpaceWatchdogEvent(
            snapshot: DiskSpaceInfo(
              path: capturePath,
              totalBytes: 0,
              freeBytes: 0,
              sampledAt: DateTime.now(),
            ),
            severity: DiskSpaceSeverity.warning,
            message: 'Disk-space monitoring failed: $e',
          ),
        );
      } finally {
        if (generation == _watchdogGeneration) {
          _watchdogPollInFlight = false;
        }
      }
    }

    // Run an immediate first poll so the user sees the current state.
    unawaited(poll());
    _watchdogTimer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  /// Stop the watchdog (if running) and close the event stream.
  void stop() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _watchdogGeneration++;
    _watchdogPollInFlight = false;
  }

  /// Dispose: cancels the timer and closes the event stream. Safe to call
  /// even if [start] was never invoked.
  void dispose() {
    stop();
    _eventsController?.close();
    _eventsController = null;
  }

  void _emit(DiskSpaceWatchdogEvent event) {
    _eventsController?.add(event);
  }

  static String _gb(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    return gb < 10 ? gb.toStringAsFixed(2) : gb.toStringAsFixed(1);
  }
}

/// Internal helper: BinningMode -> integer factors. Kept here (not on the
/// enum itself) so the model file stays free of behavioural code.
extension _BinningFactors on BinningMode {
  int get xFactor => switch (this) {
    BinningMode.one => 1,
    BinningMode.two => 2,
    BinningMode.three => 3,
    BinningMode.four => 4,
  };
  int get yFactor => xFactor; // No asymmetric binning in the model layer.
}
