import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/errors/server_error.dart';
import '../services/live_stacking_service.dart';
import '../services/logging_service.dart';
import 'backend_provider.dart';

/// Current state of the live stacking session.
enum LiveStackingStatus {
  /// No stacking session is active.
  idle,

  /// Stacking is active and processing frames.
  running,

  /// An error occurred during stacking.
  error,
}

/// Full state of the live stacking session for UI consumption.
class LiveStackingState {
  final LiveStackingStatus status;
  final LiveStackingStats stats;
  final LiveStackingConfig config;

  /// The most recent stacked preview image as u16 pixel data.
  final Uint16List? previewData;
  final int previewWidth;
  final int previewHeight;

  /// Sigma-clip pixels rejected on the most recently added frame.
  ///
  /// Derived from the cumulative total reported by Rust on each frame add:
  /// `stats.totalSigmaRejectedPixels - previous_total`. A spike in this value
  /// indicates a problem with the latest frame (clouds, satellite trail,
  /// drift, etc.) and is surfaced loudly in the UI.
  final int lastFrameSigmaRejectedPixels;

  /// Total pixel count of the most recently added frame. Captured from the
  /// stacker's output dimensions so the UI can compute a rejection rate
  /// (`lastFrameSigmaRejectedPixels / lastFrameTotalPixels`) without
  /// reaching back into [previewWidth]/[previewHeight] (which may be
  /// updated independently when a fresh preview is rendered).
  final int lastFrameTotalPixels;

  /// Error message if status == error.
  final String? errorMessage;

  /// On-disk path of the frame this stack is aligned to, when the session was
  /// started from a file.
  ///
  /// Every subsequent frame is registered onto this one, so the stack's pixel
  /// geometry IS this sub's — which is what lets a consumer resolve the
  /// stack's WCS, scale and orientation from the reference's own header
  /// instead of guessing them. Null when the stack was started from raw pixel
  /// data, when a remote host was armed without naming a reference, and
  /// whenever no stack is running.
  final String? referenceImagePath;

  const LiveStackingState({
    this.status = LiveStackingStatus.idle,
    this.stats = const LiveStackingStats(),
    this.config = const LiveStackingConfig(),
    this.previewData,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.lastFrameSigmaRejectedPixels = 0,
    this.lastFrameTotalPixels = 0,
    this.errorMessage,
    this.referenceImagePath,
  });

  /// Per-frame sigma rejection rate (0.0 .. 1.0). Returns 0 when no frame
  /// has been processed yet to avoid divide-by-zero.
  double get lastFrameSigmaRejectionRate {
    if (lastFrameTotalPixels <= 0) return 0.0;
    return lastFrameSigmaRejectedPixels / lastFrameTotalPixels;
  }

  LiveStackingState copyWith({
    LiveStackingStatus? status,
    LiveStackingStats? stats,
    LiveStackingConfig? config,
    Uint16List? previewData,
    bool clearPreviewData = false,
    int? previewWidth,
    int? previewHeight,
    int? lastFrameSigmaRejectedPixels,
    int? lastFrameTotalPixels,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? referenceImagePath,
    bool clearReferenceImagePath = false,
  }) {
    return LiveStackingState(
      status: status ?? this.status,
      stats: stats ?? this.stats,
      config: config ?? this.config,
      previewData: clearPreviewData ? null : (previewData ?? this.previewData),
      previewWidth: previewWidth ?? this.previewWidth,
      previewHeight: previewHeight ?? this.previewHeight,
      lastFrameSigmaRejectedPixels:
          lastFrameSigmaRejectedPixels ?? this.lastFrameSigmaRejectedPixels,
      lastFrameTotalPixels: lastFrameTotalPixels ?? this.lastFrameTotalPixels,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      referenceImagePath: clearReferenceImagePath
          ? null
          : (referenceImagePath ?? this.referenceImagePath),
    );
  }
}

/// StateNotifier that manages the live stacking session.
///
/// Coordinates the LiveStackingService and exposes state to the UI.
class LiveStackingNotifier extends StateNotifier<LiveStackingState> {
  final Ref _ref;

  LiveStackingNotifier(this._ref) : super(const LiveStackingState()) {
    _ref.listen(backendProvider, (previous, next) {
      final authority = _sessionAuthority;
      if (authority == null || identical(authority, next)) return;

      // A stack belongs to the backend that started it. Detach immediately
      // when the app switches rigs so pending pixels from the old host cannot
      // appear under the new connection. A remote host keeps stacking when a
      // companion disconnects, but a local stack owns a process-wide native
      // singleton and must be released before the replacement host can use it.
      final localService = authority is NetworkBackend ? null : _sessionService;
      final starting = _startInFlight;
      _invalidateSession();
      state = LiveStackingState(config: state.config);
      if (localService != null) {
        unawaited(
          () async {
            if (starting != null) {
              try {
                await starting;
              } catch (e) {
                // This is a join, not the owner of the error: whoever called
                // start() already receives that failure. We only need to know
                // the start settled so the stop below cannot race a half-built
                // native stacker — but record it so a stop that then also
                // misbehaves can be traced to the failed start.
                _logger.debug(
                  'Live stack start failed before the host swap; releasing the '
                  'local stacker anyway: $e',
                  source: 'LiveStackingNotifier',
                );
              }
            }
            await localService.stop();
          }().catchError((Object error, StackTrace stackTrace) {
            _logger.error(
              'Failed to release old-host local stacker: $error\n$stackTrace',
              source: 'LiveStackingNotifier',
            );
          }),
        );
      }
    });
  }

  LoggingService get _logger => _ref.read(loggingServiceProvider);
  LiveStackingService get _service => _ref.read(liveStackingServiceProvider);

  /// Polls the host's stacked result while remote stacking is active. The host
  /// auto-feeds captured frames into its stacker, so the client has nothing to
  /// react to except the wall clock — it refreshes the preview/stats on a
  /// cadence. Null when local (frames update the preview synchronously) or idle.
  Timer? _remotePollTimer;

  /// True once a remote poll has returned a stacked result. Before the host's
  /// first frame the poll legitimately 404s, so a failure only signals a lost
  /// host after we have seen at least one frame.
  bool _hadRemoteResult = false;

  /// Consecutive remote poll failures after the first frame. Flips to error
  /// once sustained (not on a single transient blip).
  int _consecutivePollFailures = 0;

  /// Monotonically identifies the currently displayed stacking session.
  /// Cancelling a timer cannot cancel an HTTP/FFI Future already in flight, so
  /// every completion also checks this generation and its backend authority.
  int _sessionGeneration = 0;
  Object? _sessionAuthority;
  NetworkBackend? _remoteSessionBackend;
  LiveStackingService? _sessionService;
  bool _remotePollInFlight = false;
  Future<void>? _startInFlight;
  Future<void>? _stopInFlight;
  Future<void>? _resetInFlight;

  bool _isCurrentSession(int generation, Object authority) {
    return mounted &&
        generation == _sessionGeneration &&
        identical(authority, _sessionAuthority) &&
        identical(authority, _ref.read(backendProvider));
  }

  void _invalidateSession() {
    _sessionGeneration++;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _remotePollInFlight = false;
    _hadRemoteResult = false;
    _consecutivePollFailures = 0;
    _sessionAuthority = null;
    _remoteSessionBackend = null;
    _sessionService = null;
  }

  Future<void> _trackStart(Future<void> Function() operation) {
    final active = _startInFlight;
    if (active != null) return active;
    final future = operation();
    _startInFlight = future;
    future.whenComplete(() {
      if (identical(_startInFlight, future)) _startInFlight = null;
    });
    return future;
  }

  /// Arm host-side live stacking and begin polling its preview/stats.
  ///
  /// The remote entry point: the tablet has no local reference frame, so the
  /// host arms its stacker and the next captured frame becomes the reference.
  /// Used by the UI when connected to an appliance.
  Future<void> startRemote({LiveStackingConfig? config}) {
    return _trackStart(() => _startRemote(config: config));
  }

  Future<void> _startRemote({LiveStackingConfig? config}) async {
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;

    final backend = _ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      state = state.copyWith(
        status: LiveStackingStatus.error,
        errorMessage: 'Remote live stacking requires a connected imaging host.',
      );
      return;
    }
    if (state.status == LiveStackingStatus.running &&
        identical(_sessionAuthority, backend)) {
      return;
    }

    final effectiveConfig = config ?? state.config;
    final generation = ++_sessionGeneration;
    _sessionAuthority = backend;
    _remoteSessionBackend = backend;
    _sessionService = null;
    _hadRemoteResult = false;
    _consecutivePollFailures = 0;
    state = LiveStackingState(
      status: LiveStackingStatus.running,
      config: effectiveConfig,
    );
    try {
      final stats = await backend.stackingStart(config: effectiveConfig);
      if (!_isCurrentSession(generation, backend)) return;
      state = state.copyWith(stats: stats);
      _logger.info(
        'Remote live stacking armed on host',
        source: 'LiveStackingNotifier',
      );
      _startRemotePolling(generation, backend);
    } catch (e) {
      if (!_isCurrentSession(generation, backend)) return;
      state = state.copyWith(
        status: LiveStackingStatus.error,
        errorMessage: e.toString(),
      );
      _logger.error(
        'Failed to arm remote live stacking: $e',
        source: 'LiveStackingNotifier',
      );
    }
  }

  void _startRemotePolling(int generation, NetworkBackend backend) {
    if (!_isCurrentSession(generation, backend)) return;
    _remotePollTimer?.cancel();
    // 2.5s cadence: brisk enough that the preview tracks a typical sub-minute
    // EAA exposure within a frame or two, cheap enough not to flood the LAN
    // with full-frame u16 downloads. Each tick pulls the latest host result.
    _remotePollTimer = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => _pollRemoteResult(generation, backend),
    );
    unawaited(_pollRemoteResult(generation, backend));
  }

  Future<void> _pollRemoteResult(int generation, NetworkBackend backend) async {
    if (_remotePollInFlight ||
        !_isCurrentSession(generation, backend) ||
        state.status != LiveStackingStatus.running) {
      return;
    }
    _remotePollInFlight = true;
    try {
      final result = await backend.stackingGetResult();
      if (!_isCurrentSession(generation, backend) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      _hadRemoteResult = true;
      _consecutivePollFailures = 0;
      state = state.copyWith(
        stats: result.stats,
        previewData: Uint16List.fromList(result.data),
        previewWidth: result.width,
        previewHeight: result.height,
        lastFrameTotalPixels: result.width * result.height,
        clearErrorMessage: true,
      );
    } catch (e) {
      if (!_isCurrentSession(generation, backend) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      // Before the host's first frame lands there is no result yet (404
      // no_active_stack). Only that exact response is expected; authentication,
      // transport, and malformed-payload failures must not be hidden forever.
      final isWaitingForFirstFrame =
          !_hadRemoteResult &&
          ((e is ServerError && e.code == 'no_active_stack') ||
              e.toString().contains('no_active_stack'));
      if (isWaitingForFirstFrame) return;
      _consecutivePollFailures++;
      if (_consecutivePollFailures >= 3) {
        _remotePollTimer?.cancel();
        _remotePollTimer = null;
        _logger.error(
          'Lost contact with host stacker: $e',
          source: 'LiveStackingNotifier',
        );
        // The host may still be stacking. Keep the session active so Stop is
        // available, but make the stale preview failure explicit and retryable.
        state = state.copyWith(errorMessage: 'Lost contact with host stacker');
      }
    } finally {
      _remotePollInFlight = false;
    }
  }

  /// Retry a failed remote preview poll without restarting the host stack.
  void retryRemotePolling() {
    final backend = _remoteSessionBackend;
    final authority = _sessionAuthority;
    if (backend == null ||
        authority == null ||
        state.status != LiveStackingStatus.running ||
        !identical(backend, authority) ||
        !identical(authority, _ref.read(backendProvider))) {
      return;
    }
    _consecutivePollFailures = 0;
    state = state.copyWith(clearErrorMessage: true);
    final generation = _sessionGeneration;
    _startRemotePolling(generation, backend);
  }

  /// Start a new live stacking session from a reference image file.
  Future<void> startFromFile(
    String referenceImagePath, {
    LiveStackingConfig? config,
  }) {
    return _trackStart(
      () => _startFromFile(referenceImagePath, config: config),
    );
  }

  Future<void> _startFromFile(
    String referenceImagePath, {
    LiveStackingConfig? config,
  }) async {
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;
    final authority = _ref.read(backendProvider);
    if (state.status == LiveStackingStatus.running &&
        identical(_sessionAuthority, authority)) {
      return;
    }
    final generation = ++_sessionGeneration;
    _sessionAuthority = authority;
    _remoteSessionBackend = authority is NetworkBackend ? authority : null;
    final service = authority is NetworkBackend ? null : _service;
    _sessionService = service;
    final effectiveConfig = config ?? state.config;
    state = LiveStackingState(
      status: LiveStackingStatus.running,
      config: effectiveConfig,
    );

    try {
      final stats = authority is NetworkBackend
          ? await authority.stackingStart(
              referencePath: referenceImagePath,
              config: effectiveConfig,
            )
          : await service!.startFromFile(
              referenceImagePath: referenceImagePath,
              config: effectiveConfig,
            );

      if (!_isCurrentSession(generation, authority)) return;

      // Recorded here rather than beside the status, so the state never names
      // a reference for a stack that failed to start: every frame after this
      // point is registered onto this file.
      state = state.copyWith(
        stats: stats,
        referenceImagePath: referenceImagePath,
      );

      // Surface the reference frame as the initial preview. `startFromFile`
      // only returns stats (not pixels), so we read the current stacked
      // result — which, with one frame in the stack, is the reference frame
      // itself. Without this the reference shows no preview until the second
      // frame lands, and the auto-feed broadcast would have no image to
      // publish for the very first accepted frame.
      final result = authority is NetworkBackend
          ? await authority.stackingGetResult()
          : await service!.getCurrentResult();
      if (!_isCurrentSession(generation, authority)) return;
      state = state.copyWith(
        previewData: Uint16List.fromList(result.data),
        previewWidth: result.width,
        previewHeight: result.height,
        lastFrameTotalPixels: result.width * result.height,
      );

      _logger.info(
        'Live stacking started: ${stats.stackedFrameCount} frames',
        source: 'LiveStackingNotifier',
      );
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      state = state.copyWith(
        status: LiveStackingStatus.error,
        errorMessage: e.toString(),
      );
      _logger.error(
        'Failed to start live stacking: $e',
        source: 'LiveStackingNotifier',
      );
    }
  }

  /// Start a new live stacking session from raw pixel data.
  Future<void> startFromData({
    required int width,
    required int height,
    required List<int> data,
    LiveStackingConfig? config,
  }) {
    return _trackStart(
      () => _startFromData(
        width: width,
        height: height,
        data: data,
        config: config,
      ),
    );
  }

  Future<void> _startFromData({
    required int width,
    required int height,
    required List<int> data,
    LiveStackingConfig? config,
  }) async {
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;
    final authority = _ref.read(backendProvider);
    if (state.status == LiveStackingStatus.running &&
        identical(_sessionAuthority, authority)) {
      return;
    }
    final generation = ++_sessionGeneration;
    _sessionAuthority = authority;
    _remoteSessionBackend = null;
    final service = _service;
    _sessionService = service;
    final effectiveConfig = config ?? state.config;
    state = LiveStackingState(
      status: LiveStackingStatus.running,
      config: effectiveConfig,
    );

    try {
      final stats = await service.startFromData(
        width: width,
        height: height,
        data: data,
        config: effectiveConfig,
      );

      if (!_isCurrentSession(generation, authority)) return;

      state = state.copyWith(stats: stats);

      // Mirror startFromFile: surface the reference frame as the initial
      // preview so the panel and any auto-feed broadcast have an image
      // immediately rather than only after the second frame.
      final result = await service.getCurrentResult();
      if (!_isCurrentSession(generation, authority)) return;
      state = state.copyWith(
        previewData: Uint16List.fromList(result.data),
        previewWidth: result.width,
        previewHeight: result.height,
        lastFrameTotalPixels: result.width * result.height,
      );
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      state = state.copyWith(
        status: LiveStackingStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Add a frame to the stack from a file.
  Future<void> addFrameFromFile(String imagePath) async {
    if (state.status != LiveStackingStatus.running) return;
    final generation = _sessionGeneration;
    final authority = _sessionAuthority;
    if (authority == null) return;

    try {
      final remote = _remoteSessionBackend;
      final service = _sessionService;
      final result = remote != null
          ? await remote.stackingAddFrame(imagePath)
          : await service!.addFrameFromFile(imagePath);

      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }

      final previousTotal = state.stats.totalSigmaRejectedPixels;
      final newTotal = result.stats.totalSigmaRejectedPixels;
      // Diff against the previous cumulative count. Rust resets the counter
      // on stacker reset, so a negative delta would indicate a state
      // inconsistency -- clamp to 0 rather than render garbage.
      final perFrameRejected = newTotal >= previousTotal
          ? newTotal - previousTotal
          : 0;
      final totalPixels = result.width * result.height;

      state = state.copyWith(
        stats: result.stats,
        previewData: Uint16List.fromList(result.data),
        previewWidth: result.width,
        previewHeight: result.height,
        lastFrameSigmaRejectedPixels: perFrameRejected,
        lastFrameTotalPixels: totalPixels,
      );
    } catch (e) {
      if (!mounted) return;
      // Frame rejection is not a fatal error -- log and continue
      _logger.warning('Frame rejected: $e', source: 'LiveStackingNotifier');
      await _publishRejectionStats(generation, authority, e);
    }
  }

  /// Add a frame to the stack from raw pixel data.
  Future<void> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
  }) async {
    if (state.status != LiveStackingStatus.running) return;
    final generation = _sessionGeneration;
    final authority = _sessionAuthority;
    if (authority == null) return;

    try {
      final service = _sessionService;
      final result = await service!.addFrameFromData(
        width: width,
        height: height,
        data: data,
      );

      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }

      final previousTotal = state.stats.totalSigmaRejectedPixels;
      final newTotal = result.stats.totalSigmaRejectedPixels;
      final perFrameRejected = newTotal >= previousTotal
          ? newTotal - previousTotal
          : 0;
      final totalPixels = result.width * result.height;

      state = state.copyWith(
        stats: result.stats,
        previewData: Uint16List.fromList(result.data),
        previewWidth: result.width,
        previewHeight: result.height,
        lastFrameSigmaRejectedPixels: perFrameRejected,
        lastFrameTotalPixels: totalPixels,
      );
    } catch (e) {
      if (!mounted) return;
      _logger.warning('Frame rejected: $e', source: 'LiveStackingNotifier');
      await _publishRejectionStats(generation, authority, e);
    }
  }

  /// Publish the stacker's own tally after it REFUSED a frame.
  ///
  /// A refusal still counts: the engine increments `totalFramesAttempted` and
  /// `rejectedAlignmentFailures` before returning the error. Dropping the
  /// error on the floor left every counter frozen at the last accepted frame,
  /// so a session that rejected all 179 of its frames displayed
  /// `Total Attempted 1 · Rejected (Alignment) 0` — the panel reported nothing
  /// was happening while the engine was throwing every frame away.
  ///
  /// Best effort by construction: if the tally cannot be read back the
  /// previous counters stand rather than being replaced by a guess.
  Future<void> _publishRejectionStats(
    int generation,
    Object authority,
    Object error,
  ) async {
    LiveStackingStats? stats;
    if (error is LiveStackingFrameRejected) {
      stats = error.stats;
    } else {
      try {
        final remote = _remoteSessionBackend;
        stats = remote != null
            ? await remote.stackingGetStats()
            : await _sessionService?.getStats();
      } catch (_) {
        return;
      }
    }
    if (stats == null) return;
    if (!_isCurrentSession(generation, authority) ||
        state.status != LiveStackingStatus.running) {
      return;
    }
    state = state.copyWith(stats: stats);
  }

  /// Update the stacking configuration.
  void updateConfig(LiveStackingConfig config) {
    state = state.copyWith(config: config);
  }

  /// Reset the stack (clear accumulated data, keep reference).
  Future<void> reset() {
    final active = _resetInFlight;
    if (active != null) return active;
    final future = _reset();
    _resetInFlight = future;
    future.whenComplete(() {
      if (identical(_resetInFlight, future)) _resetInFlight = null;
    });
    return future;
  }

  Future<void> _reset() async {
    final starting = _startInFlight;
    if (starting != null) await starting;
    final authority = _sessionAuthority;
    if (authority == null || state.status != LiveStackingStatus.running) return;
    final generation = ++_sessionGeneration;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    try {
      final remote = _remoteSessionBackend;
      final service = _sessionService;
      if (remote != null) {
        await remote.stackingReset();
      } else {
        await service!.reset();
      }
      if (!_isCurrentSession(generation, authority)) return;
      // Rebuild from scratch (preserving config) so per-frame counters drop
      // back to zero alongside the cleared cumulative stats.
      state = LiveStackingState(status: state.status, config: state.config);
      if (remote != null) _startRemotePolling(generation, remote);
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      _logger.error(
        'Failed to reset stacker: $e',
        source: 'LiveStackingNotifier',
      );
      state = state.copyWith(errorMessage: 'Failed to reset stack: $e');
      final remote = _remoteSessionBackend;
      if (remote != null) _startRemotePolling(generation, remote);
    }
  }

  /// Stop stacking and release resources.
  Future<void> stop() {
    final active = _stopInFlight;
    if (active != null) return active;
    final future = _stop();
    _stopInFlight = future;
    future.whenComplete(() {
      if (identical(_stopInFlight, future)) _stopInFlight = null;
    });
    return future;
  }

  Future<void> _stop() async {
    final config = state.config;
    final authority = _sessionAuthority ?? _ref.read(backendProvider);
    final remote = _remoteSessionBackend;
    final service = _sessionService;
    final generation = ++_sessionGeneration;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _remotePollInFlight = false;
    _hadRemoteResult = false;
    _consecutivePollFailures = 0;
    try {
      // A Stop racing Start must be ordered after the host arm completes;
      // otherwise Stop can observe no active stack and Start can arm it later.
      final starting = _startInFlight;
      if (starting != null) await starting;
      if (remote != null) {
        await remote.stackingStop();
      } else if (service != null) {
        await service.stop();
      }
    } catch (e) {
      _logger.error(
        'Failed to stop stacker: $e',
        source: 'LiveStackingNotifier',
      );
      if (mounted &&
          generation == _sessionGeneration &&
          identical(authority, _sessionAuthority)) {
        state = state.copyWith(errorMessage: 'Failed to stop stack: $e');
      }
      return;
    }

    if (!mounted || generation != _sessionGeneration) return;
    _sessionAuthority = null;
    _remoteSessionBackend = null;
    _sessionService = null;
    state = LiveStackingState(config: config);
  }

  @override
  void dispose() {
    _invalidateSession();
    super.dispose();
  }
}

/// Provider for the live stacking state.
final liveStackingProvider =
    StateNotifierProvider<LiveStackingNotifier, LiveStackingState>((ref) {
      return LiveStackingNotifier(ref);
    });

/// Convenience provider for whether stacking is active.
final liveStackingIsActiveProvider = Provider<bool>((ref) {
  return ref.watch(liveStackingProvider).status == LiveStackingStatus.running;
});
