import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'linked_host.dart';
import 'async_scope.dart';
import '../errors/error_text.dart';
import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../services/live_stacking_service.dart';
import '../utils/logging_service.dart';
import '../utils/poll_pace.dart';
import 'backend_provider.dart';
import 'live_stacking_service_provider.dart';
import 'logging_service_provider.dart';
import '../models/imaging/live_stacking_models.dart';
import '../errors/server_error.dart';

/// Canonical display order for astrophotography filters in filter switchers.
const List<String> kLiveStackFilterSortOrder = <String>[
  'L',
  'Lum',
  'Luminance',
  'R',
  'Red',
  'G',
  'Green',
  'B',
  'Blue',
  'Ha',
  'H-alpha',
  'OIII',
  'O3',
  'SII',
  'S2',
];

int _filterSortRank(String key) {
  if (key == kDefaultLiveStackFilterKey) return 10000;
  final lower = key.toLowerCase();
  for (var i = 0; i < kLiveStackFilterSortOrder.length; i++) {
    if (kLiveStackFilterSortOrder[i].toLowerCase() == lower) return i;
  }
  return 500;
}

/// Compare two filter keys into natural astrophotography filter order.
int compareLiveStackFilters(String a, String b) {
  final ra = _filterSortRank(a);
  final rb = _filterSortRank(b);
  if (ra != rb) return ra.compareTo(rb);
  return a.toLowerCase().compareTo(b.toLowerCase());
}

/// Current state of the live stacking session.
enum LiveStackingStatus {
  /// No stacking session is active.
  idle,

  /// Stacking is active and processing frames.
  running,

  /// An error occurred during stacking.
  error,
}

/// Snapshot of one per-filter live stack slot.
class FilterStackSnapshot {
  final String filterKey;
  final LiveStackingStats stats;
  final Uint16List? previewData;
  final int previewWidth;
  final int previewHeight;
  final int channels;
  final int lastFrameSigmaRejectedPixels;
  final int lastFrameTotalPixels;
  final String? referenceImagePath;
  final int revision;
  final List<LiveStackFrameEvent> events;

  const FilterStackSnapshot({
    required this.filterKey,
    this.stats = const LiveStackingStats(),
    this.previewData,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.channels = 1,
    this.lastFrameSigmaRejectedPixels = 0,
    this.lastFrameTotalPixels = 0,
    this.referenceImagePath,
    this.revision = 0,
    this.events = const [],
  });

  bool get hasPixels =>
      previewData != null && previewWidth > 0 && previewHeight > 0;

  double get lastFrameSigmaRejectionRate {
    if (lastFrameTotalPixels <= 0) return 0.0;
    return lastFrameSigmaRejectedPixels / lastFrameTotalPixels;
  }

  double get totalIntegrationSecs => stats.totalIntegrationSecs;

  FilterStackSnapshot copyWith({
    LiveStackingStats? stats,
    Uint16List? previewData,
    bool clearPreviewData = false,
    int? previewWidth,
    int? previewHeight,
    int? channels,
    int? lastFrameSigmaRejectedPixels,
    int? lastFrameTotalPixels,
    String? referenceImagePath,
    bool clearReferenceImagePath = false,
    int? revision,
    List<LiveStackFrameEvent>? events,
  }) {
    return FilterStackSnapshot(
      filterKey: filterKey,
      stats: stats ?? this.stats,
      previewData: clearPreviewData ? null : (previewData ?? this.previewData),
      previewWidth: previewWidth ?? this.previewWidth,
      previewHeight: previewHeight ?? this.previewHeight,
      channels: channels ?? this.channels,
      lastFrameSigmaRejectedPixels:
          lastFrameSigmaRejectedPixels ?? this.lastFrameSigmaRejectedPixels,
      lastFrameTotalPixels: lastFrameTotalPixels ?? this.lastFrameTotalPixels,
      referenceImagePath: clearReferenceImagePath
          ? null
          : (referenceImagePath ?? this.referenceImagePath),
      revision: revision ?? this.revision,
      events: events ?? this.events,
    );
  }
}

/// Full state of the live stacking session for UI consumption.
class LiveStackingState {
  final LiveStackingStatus status;
  final LiveStackingStats stats;
  final LiveStackingConfig config;

  /// True when live stacking is armed to automatically capture and stack
  /// incoming frames (even before the first frame arrives to create a filter
  /// slot).
  final bool isArmed;

  /// Active per-filter live stacks keyed by normalized filter name (`L`, `Ha`,
  /// `OIII`, `Unfiltered`, ...).
  final Map<String, FilterStackSnapshot> filterStacks;

  /// The filter stack currently selected for preview, statistics, and Darkroom
  /// processing.
  final String? selectedFilterKey;

  /// Chronological (newest-first) log of evaluated frames across all filters.
  final List<LiveStackFrameEvent> frameLog;

  /// The most recent stacked preview image as u16 pixel data (mirrors the
  /// selected filter stack for backward compatibility with all existing viewers).
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
    this.isArmed = false,
    this.filterStacks = const {},
    this.selectedFilterKey,
    this.frameLog = const [],
    this.previewData,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.lastFrameSigmaRejectedPixels = 0,
    this.lastFrameTotalPixels = 0,
    this.errorMessage,
    this.referenceImagePath,
  });

  /// Sorted list of filter keys currently holding live stacks.
  List<String> get availableFilters {
    if (filterStacks.isEmpty) return const [];
    final keys = filterStacks.keys.toList(growable: false)
      ..sort(compareLiveStackFilters);
    return keys;
  }

  /// Currently selected filter stack snapshot, or null when none exist.
  FilterStackSnapshot? get activeFilterStack {
    if (filterStacks.isEmpty) return null;
    if (selectedFilterKey != null &&
        filterStacks.containsKey(selectedFilterKey)) {
      return filterStacks[selectedFilterKey];
    }
    return filterStacks[availableFilters.first];
  }

  /// True when live stacking is running or armed for incoming frames.
  bool get isActiveOrArmed => status == LiveStackingStatus.running || isArmed;

  /// True when at least one stack has accumulated frames.
  bool get hasStackedFrames =>
      totalFramesAcrossFilters > 0 || stats.stackedFrameCount > 0;

  /// Total stacked frames across all active filter slots.
  int get totalFramesAcrossFilters {
    if (filterStacks.isEmpty) return stats.stackedFrameCount;
    var total = 0;
    for (final s in filterStacks.values) {
      total += s.stats.stackedFrameCount;
    }
    return total;
  }

  /// Total integration seconds across all active filter slots.
  double get totalIntegrationAcrossFilters {
    if (filterStacks.isEmpty) return stats.totalIntegrationSecs;
    var total = 0.0;
    for (final s in filterStacks.values) {
      total += s.stats.totalIntegrationSecs;
    }
    return total;
  }

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
    bool? isArmed,
    Map<String, FilterStackSnapshot>? filterStacks,
    String? selectedFilterKey,
    bool clearSelectedFilterKey = false,
    List<LiveStackFrameEvent>? frameLog,
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
      isArmed: isArmed ?? this.isArmed,
      filterStacks: filterStacks ?? this.filterStacks,
      selectedFilterKey: clearSelectedFilterKey
          ? null
          : (selectedFilterKey ?? this.selectedFilterKey),
      frameLog: frameLog ?? this.frameLog,
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
      final localService = _sessionService;
      final starting = _startInFlight;
      final ingesting = _ingestChain;
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
            try {
              await ingesting;
            } catch (e) {
              _logger.debug(
                'Live stack ingest settled with error before host-swap release: $e',
                source: 'LiveStackingNotifier',
              );
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
  SkotiqBackend? _sessionAuthority;
  HostLiveStack? _remoteSessionBackend;
  LiveStackingService? _sessionService;
  bool _remotePollInFlight = false;
  Future<void>? _startInFlight;
  Future<void>? _stopInFlight;
  Future<void>? _resetInFlight;
  Future<void> _ingestChain = Future<void>.value();

  /// Reuse an existing [Uint16List] without copying multi-megapixel buffers on
  /// the Flutter UI isolate.
  static Uint16List _asUint16List(List<int> data) =>
      data is Uint16List ? data : Uint16List.fromList(data);

  bool _isCurrentSession(int generation, Object authority) {
    return mounted &&
        generation == _sessionGeneration &&
        identical(authority, _sessionAuthority) &&
        _ref.scopeOver<Object>(backendProvider, authority).isCurrent;
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
    final remote = _ref.read(linkedHostLiveStackProvider);
    if (remote == null) {
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
    _remoteSessionBackend = remote;
    _sessionService = null;
    _hadRemoteResult = false;
    _consecutivePollFailures = 0;
    state = LiveStackingState(
      status: LiveStackingStatus.running,
      isArmed: true,
      config: effectiveConfig,
    );
    try {
      final stats = await remote.stackingStart(config: effectiveConfig);
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
        errorMessage: userFacingError(e),
      );
      _logger.error(
        'Failed to arm remote live stacking: $e',
        source: 'LiveStackingNotifier',
      );
    }
  }

  void _startRemotePolling(int generation, SkotiqBackend backend) {
    if (!_isCurrentSession(generation, backend)) return;
    _remotePollTimer?.cancel();
    // 2.5s cadence: brisk enough that the preview tracks a typical sub-minute
    // EAA exposure within a frame or two, cheap enough not to flood the LAN
    // with full-frame u16 downloads. Each tick pulls the latest host result.
    _remotePollTimer = pacedPeriodicTimer(
      const Duration(milliseconds: 2500),
      () => _pollRemoteResult(generation, backend),
    );
    unawaited(_pollRemoteResult(generation, backend));
  }

  Future<void> _pollRemoteResult(int generation, SkotiqBackend backend) async {
    final remote = _remoteSessionBackend;
    if (remote == null ||
        _remotePollInFlight ||
        !_isCurrentSession(generation, backend) ||
        state.status != LiveStackingStatus.running) {
      return;
    }
    _remotePollInFlight = true;
    try {
      final result = await remote.stackingGetResult();
      if (!_isCurrentSession(generation, backend) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      _hadRemoteResult = true;
      _consecutivePollFailures = 0;
      state = state.copyWith(
        stats: result.stats,
        previewData: _asUint16List(result.data),
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
    final remote = _remoteSessionBackend;
    final authority = _sessionAuthority;
    if (remote == null ||
        authority == null ||
        state.status != LiveStackingStatus.running ||
        !identical(remote, _ref.read(linkedHostLiveStackProvider)) ||
        _ref.backendScopeOver(authority).isStale) {
      return;
    }
    _consecutivePollFailures = 0;
    state = state.copyWith(clearErrorMessage: true);
    final generation = _sessionGeneration;
    _startRemotePolling(generation, authority);
  }

  /// Arm live stacking to automatically stack incoming captured frames without
  /// requiring the user to pick a reference file up front.
  ///
  /// On a remote connection, delegates to [startRemote]. Locally, arms the
  /// session in memory so the next frame captured (manual or sequenced) starts
  /// its filter's stack automatically.
  Future<void> arm({LiveStackingConfig? config}) {
    final remote = _ref.read(linkedHostLiveStackProvider);
    if (remote != null) {
      return startRemote(config: config);
    }
    return _trackStart(() => _armLocal(config: config));
  }

  Future<void> _armLocal({LiveStackingConfig? config}) async {
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;
    final authority = _ref.read(backendProvider);
    if (state.status == LiveStackingStatus.running &&
        identical(_sessionAuthority, authority)) {
      if (!state.isArmed) {
        state = state.copyWith(isArmed: true);
      }
      return;
    }
    ++_sessionGeneration;
    _sessionAuthority = authority;
    _remoteSessionBackend = null;
    _sessionService = _service;
    final effectiveConfig = config ?? state.config;
    state = LiveStackingState(
      status: LiveStackingStatus.running,
      isArmed: true,
      config: effectiveConfig,
    );
    _logger.info(
      'Local live stacking armed — waiting for incoming light frames',
      source: 'LiveStackingNotifier',
    );
  }

  /// Switch which per-filter live stack is currently displayed on the canvas,
  /// Night Control, and Darkroom live pipeline.
  void selectFilter(String filterKey) {
    final snapshot = state.filterStacks[filterKey];
    if (snapshot == null) return;
    if (state.selectedFilterKey == filterKey) return;
    state = _mirrorSelectedFilter(
      state.copyWith(selectedFilterKey: filterKey),
      snapshot,
    );
  }

  /// Mirror [snapshot] onto the top-level preview/stats fields so legacy
  /// consumers (DepthLock, broadcast, existing preview widgets) stay in sync.
  LiveStackingState _mirrorSelectedFilter(
    LiveStackingState base,
    FilterStackSnapshot snapshot,
  ) {
    return base.copyWith(
      selectedFilterKey: snapshot.filterKey,
      stats: snapshot.stats,
      previewData: snapshot.previewData,
      clearPreviewData: snapshot.previewData == null,
      previewWidth: snapshot.previewWidth,
      previewHeight: snapshot.previewHeight,
      lastFrameSigmaRejectedPixels: snapshot.lastFrameSigmaRejectedPixels,
      lastFrameTotalPixels: snapshot.lastFrameTotalPixels,
      referenceImagePath: snapshot.referenceImagePath,
      clearReferenceImagePath: snapshot.referenceImagePath == null,
    );
  }

  List<LiveStackFrameEvent> _prependEvent(
    List<LiveStackFrameEvent> existing,
    LiveStackFrameEvent event,
  ) {
    const cap = 200;
    final next = <LiveStackFrameEvent>[event, ...existing];
    if (next.length > cap) next.removeRange(cap, next.length);
    return List<LiveStackFrameEvent>.unmodifiable(next);
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

  /// Start a live stacking slot for a specific optical filter.
  Future<void> startFromFileForFilter(
    String referenceImagePath, {
    required String filterKey,
    LiveStackingConfig? config,
  }) {
    return _trackStart(
      () => _startFromFile(
        referenceImagePath,
        config: config,
        filterKey: filterKey,
      ),
    );
  }

  Future<void> _startFromFile(
    String referenceImagePath, {
    LiveStackingConfig? config,
    String? filterKey,
  }) async {
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;
    final authority = _ref.read(backendProvider);
    final normalizedFilter = filterKey != null
        ? normalizeLiveStackFilterKey(filterKey)
        : null;
    final isAlreadyRunningOnAuthority =
        state.status == LiveStackingStatus.running &&
        identical(_sessionAuthority, authority);
    if (isAlreadyRunningOnAuthority &&
        (normalizedFilter == null ||
            state.filterStacks.containsKey(normalizedFilter))) {
      return;
    }

    final int generation;
    final LiveStackingConfig effectiveConfig;
    final HostLiveStack? remote;
    final LiveStackingService? service;

    if (isAlreadyRunningOnAuthority) {
      generation = _sessionGeneration;
      effectiveConfig = config ?? state.config;
      remote = _remoteSessionBackend;
      service = _sessionService;
    } else {
      generation = ++_sessionGeneration;
      _sessionAuthority = authority;
      remote = _ref.read(linkedHostLiveStackProvider);
      _remoteSessionBackend = remote;
      service = remote != null ? null : _service;
      _sessionService = service;
      effectiveConfig = config ?? state.config;
      state = LiveStackingState(
        status: LiveStackingStatus.running,
        isArmed: true,
        config: effectiveConfig,
      );
    }

    try {
      final stats = remote != null
          ? await remote.stackingStart(
              referencePath: referenceImagePath,
              config: effectiveConfig,
              filterKey: normalizedFilter,
            )
          : (normalizedFilter != null
                ? await service!.startFromFileForFilter(
                    filterKey: normalizedFilter,
                    referenceImagePath: referenceImagePath,
                    config: effectiveConfig,
                  )
                : await service!.startFromFile(
                    referenceImagePath: referenceImagePath,
                    config: effectiveConfig,
                  ));

      if (!_isCurrentSession(generation, authority)) return;

      // Recorded here rather than beside the status, so the state never names
      // a reference for a stack that failed to start: every frame after this
      // point is registered onto this file.
      if (!isAlreadyRunningOnAuthority) {
        state = state.copyWith(
          stats: stats,
          referenceImagePath: referenceImagePath,
        );
      }

      // Surface the reference frame as the initial preview.
      final result = remote != null
          ? await remote.stackingGetResult()
          : (normalizedFilter != null
                ? await service!.getCurrentResultForFilter(normalizedFilter)
                : await service!.getCurrentResult());
      if (!_isCurrentSession(generation, authority)) return;

      final resolvedKey =
          normalizedFilter ?? normalizeLiveStackFilterKey(result.filterKey);
      final preview = _asUint16List(result.data);
      final totalPixels = result.width * result.height;
      final refEvent =
          result.lastEvent ??
          LiveStackFrameEvent(
            sequenceIndex: 1,
            filterKey: resolvedKey,
            sourceLabel: p.basename(referenceImagePath),
            accepted: true,
            timestamp: DateTime.now().toUtc(),
          );
      final snapshot = FilterStackSnapshot(
        filterKey: resolvedKey,
        stats: result.stats,
        previewData: preview,
        previewWidth: result.width,
        previewHeight: result.height,
        channels: result.channels,
        lastFrameSigmaRejectedPixels: 0,
        lastFrameTotalPixels: totalPixels,
        referenceImagePath: referenceImagePath,
        revision: result.revision > 0 ? result.revision : 1,
        events: [refEvent],
      );

      final updatedStacks = Map<String, FilterStackSnapshot>.of(
        state.filterStacks,
      )..[resolvedKey] = snapshot;
      final updatedLog = _prependEvent(state.frameLog, refEvent);
      final nextSelected = state.selectedFilterKey ?? resolvedKey;
      final selectedSnap = updatedStacks[nextSelected] ?? snapshot;

      state = _mirrorSelectedFilter(
        state.copyWith(
          filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
            updatedStacks,
          ),
          selectedFilterKey: nextSelected,
          frameLog: updatedLog,
          clearErrorMessage: true,
        ),
        selectedSnap,
      );

      _logger.info(
        'Live stacking started for $resolvedKey: ${stats.stackedFrameCount} frames',
        source: 'LiveStackingNotifier',
      );
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      if (!isAlreadyRunningOnAuthority) {
        state = state.copyWith(
          status: LiveStackingStatus.error,
          errorMessage: userFacingError(e),
        );
      } else {
        final key = normalizeLiveStackFilterKey(filterKey);
        final rejEvent = LiveStackFrameEvent(
          sequenceIndex: 1,
          filterKey: key,
          sourceLabel: p.basename(referenceImagePath),
          accepted: false,
          rejectionReason: userFacingError(e),
          timestamp: DateTime.now().toUtc(),
        );
        state = state.copyWith(
          frameLog: _prependEvent(state.frameLog, rejEvent),
        );
      }
      _logger.error(
        'Failed to start live stacking: $e',
        source: 'LiveStackingNotifier',
      );
    }
  }

  /// Start a new live stacking session aligned to [referencePath], then add
  /// [framePaths] in order.
  ///
  /// Frames that are already on disk join the stack here; frames captured
  /// afterwards arrive through [addFrameFromFile] as usual. A Stop or a host
  /// change ends the catch-up after the frame in flight.
  Future<void> startFromFrames(
    String referencePath,
    List<String> framePaths, {
    LiveStackingConfig? config,
  }) {
    return _trackStart(() async {
      await _startFromFile(referencePath, config: config);
      final generation = _sessionGeneration;
      final authority = _sessionAuthority;
      for (final path in framePaths) {
        if (authority == null ||
            !_isCurrentSession(generation, authority) ||
            state.status != LiveStackingStatus.running) {
          return;
        }
        await addFrameFromFile(path);
      }
    });
  }

  /// Start a new live stacking session from raw pixel data carrying
  /// [pedestal] ADU (0 for none).
  Future<void> startFromData({
    required int width,
    required int height,
    required List<int> data,
    required double pedestal,
    LiveStackingConfig? config,
    String? filterKey,
  }) {
    return _trackStart(
      () => _startFromData(
        width: width,
        height: height,
        data: data,
        pedestal: pedestal,
        config: config,
        filterKey: filterKey,
      ),
    );
  }

  Future<void> _startFromData({
    required int width,
    required int height,
    required List<int> data,
    required double pedestal,
    LiveStackingConfig? config,
    String? filterKey,
  }) async {
    final stopping = _stopInFlight;
    if (stopping != null) await stopping;
    final authority = _ref.read(backendProvider);
    final normalizedFilter = filterKey != null
        ? normalizeLiveStackFilterKey(filterKey)
        : null;
    final isAlreadyRunningOnAuthority =
        state.status == LiveStackingStatus.running &&
        identical(_sessionAuthority, authority);
    if (isAlreadyRunningOnAuthority &&
        (normalizedFilter == null ||
            state.filterStacks.containsKey(normalizedFilter))) {
      return;
    }
    final int generation;
    final LiveStackingService service;
    final LiveStackingConfig effectiveConfig;
    if (isAlreadyRunningOnAuthority) {
      generation = _sessionGeneration;
      service = _sessionService ?? _service;
      effectiveConfig = config ?? state.config;
    } else {
      generation = ++_sessionGeneration;
      _sessionAuthority = authority;
      _remoteSessionBackend = null;
      service = _service;
      _sessionService = service;
      effectiveConfig = config ?? state.config;
      state = LiveStackingState(
        status: LiveStackingStatus.running,
        isArmed: true,
        config: effectiveConfig,
      );
    }

    try {
      final stats = normalizedFilter != null
          ? await service.startFromDataForFilter(
              filterKey: normalizedFilter,
              width: width,
              height: height,
              data: data,
              pedestal: pedestal,
              config: effectiveConfig,
            )
          : await service.startFromData(
              width: width,
              height: height,
              data: data,
              pedestal: pedestal,
              config: effectiveConfig,
            );

      if (!_isCurrentSession(generation, authority)) return;

      if (!isAlreadyRunningOnAuthority) {
        state = state.copyWith(stats: stats);
      }

      // Mirror startFromFile: surface the reference frame as the initial
      // preview so the panel and any auto-feed broadcast have an image
      // immediately rather than only after the second frame.
      final result = normalizedFilter != null
          ? await service.getCurrentResultForFilter(normalizedFilter)
          : await service.getCurrentResult();
      if (!_isCurrentSession(generation, authority)) return;

      final resolvedKey =
          normalizedFilter ?? normalizeLiveStackFilterKey(result.filterKey);
      final preview = _asUint16List(result.data);
      final totalPixels = result.width * result.height;
      final refEvent =
          result.lastEvent ??
          LiveStackFrameEvent(
            sequenceIndex: 1,
            filterKey: resolvedKey,
            sourceLabel: 'in-memory',
            accepted: true,
            timestamp: DateTime.now().toUtc(),
          );
      final snapshot = FilterStackSnapshot(
        filterKey: resolvedKey,
        stats: result.stats,
        previewData: preview,
        previewWidth: result.width,
        previewHeight: result.height,
        channels: result.channels,
        lastFrameSigmaRejectedPixels: 0,
        lastFrameTotalPixels: totalPixels,
        revision: result.revision > 0 ? result.revision : 1,
        events: [refEvent],
      );
      final updatedStacks = Map<String, FilterStackSnapshot>.of(
        state.filterStacks,
      )..[resolvedKey] = snapshot;
      state = _mirrorSelectedFilter(
        state.copyWith(
          filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
            updatedStacks,
          ),
          selectedFilterKey: state.selectedFilterKey ?? resolvedKey,
          frameLog: _prependEvent(state.frameLog, refEvent),
        ),
        updatedStacks[state.selectedFilterKey ?? resolvedKey] ?? snapshot,
      );
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      state = state.copyWith(
        status: LiveStackingStatus.error,
        errorMessage: userFacingError(e),
      );
    }
  }

  /// Run [body] after every earlier ingest step, including one that failed.
  ///
  /// A step that throws completes its own caller and must not fail the chain:
  /// the next step is attached with [Future.then], which never runs when the
  /// previous future completed with an error, so its completer would stay
  /// pending forever.
  Future<void> _enqueueIngest(Future<void> Function() body) {
    final completer = Completer<void>();
    final settled = _ingestChain.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final done = settled.then((_) async {
      try {
        await body();
      } catch (error) {
        var rendered = 'Live stack ingest step failed';
        try {
          rendered = 'Live stack ingest step failed: $error';
        } catch (_) {}
        _logger.error(rendered, source: 'LiveStackingNotifier');
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    _ingestChain = done;
    return completer.future;
  }

  bool _stopFoundNoStack(Object error) {
    try {
      return error.toString().toLowerCase().contains(
        'live stacker not initialized',
      );
    } catch (_) {
      return false;
    }
  }

  /// Add a frame to the stack from a file (legacy single-argument signature).
  Future<void> addFrameFromFile(String imagePath) {
    return addFrameFromFileWithMetadata(imagePath);
  }

  /// Add a frame to the stack from a file, with optional filter routing and
  /// quality-gate metadata.
  ///
  /// Serializes frame ingestion per session so rapid exposure bursts never load
  /// multiple multi-megapixel FITS files concurrently into RAM or race state
  /// updates, while cancelling queued frames immediately if the session stops.
  Future<void> addFrameFromFileWithMetadata(
    String imagePath, {
    String? filter,
    double? exposureSecs,
    double? hfr,
    int? starCount,
  }) {
    if (state.status != LiveStackingStatus.running) {
      return Future<void>.value();
    }
    final generation = _sessionGeneration;
    final authority = _sessionAuthority;
    if (authority == null) return Future<void>.value();

    return _enqueueIngest(() async {
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      await _ingestFrameFromFileWithMetadata(
        imagePath,
        generation: generation,
        authority: authority,
        filter: filter,
        exposureSecs: exposureSecs,
        hfr: hfr,
        starCount: starCount,
      );
    });
  }

  Future<void> _ingestFrameFromFileWithMetadata(
    String imagePath, {
    required int generation,
    required Object authority,
    String? filter,
    double? exposureSecs,
    double? hfr,
    int? starCount,
  }) async {
    if (state.status != LiveStackingStatus.running) return;

    final targetFilter = state.config.separateByFilter
        ? (filter != null
              ? normalizeLiveStackFilterKey(filter)
              : (state.selectedFilterKey ?? kDefaultLiveStackFilterKey))
        : (state.selectedFilterKey ?? kDefaultLiveStackFilterKey);

    // Evaluate optional pre-stacking quality gates with full transparency.
    final maxHfr = state.config.maxHfrPx;
    if (maxHfr != null && hfr != null && hfr.isFinite && hfr > maxHfr) {
      final reason =
          'Skipped by HFR gate: ${hfr.toStringAsFixed(2)} px > '
          '${maxHfr.toStringAsFixed(2)} px';
      _recordLocalGateRejection(
        filterKey: targetFilter,
        sourceLabel: p.basename(imagePath),
        reason: reason,
        detectedStars: starCount ?? 0,
        exposureSecs: exposureSecs,
      );
      return;
    }
    final minStars = state.config.minStarCount;
    if (minStars != null && starCount != null && starCount < minStars) {
      final reason =
          'Skipped by star-count gate: $starCount stars < $minStars required';
      _recordLocalGateRejection(
        filterKey: targetFilter,
        sourceLabel: p.basename(imagePath),
        reason: reason,
        detectedStars: starCount,
        exposureSecs: exposureSecs,
      );
      return;
    }

    final remote = _remoteSessionBackend;
    final service = _sessionService;

    // If locally armed (no stack yet) OR a brand-new filter arrived while
    // `separateByFilter` is active, initialize that filter's stack with this
    // frame as its reference!
    final needsNewFilterStack =
        remote == null &&
        service != null &&
        ((state.isArmed && state.filterStacks.isEmpty) ||
            (state.config.separateByFilter &&
                filter != null &&
                !state.filterStacks.containsKey(targetFilter)));

    if (needsNewFilterStack) {
      await _startFilterSlotInRunningSession(
        generation: generation,
        authority: authority,
        service: service,
        filterKey: targetFilter,
        referenceImagePath: imagePath,
        exposureSecs: exposureSecs,
      );
      return;
    }

    try {
      final useExplicitFilter =
          remote == null &&
          filter != null &&
          state.filterStacks.containsKey(targetFilter);
      final result = remote != null
          ? await remote.stackingAddFrame(imagePath)
          : (useExplicitFilter
                ? await service!.addFrameFromFileForFilter(
                    imagePath,
                    filterKey: targetFilter,
                  )
                : await service!.addFrameFromFile(imagePath));

      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }

      _applyAcceptedResult(
        result: result,
        fallbackFilterKey: targetFilter,
        sourceLabel: p.basename(imagePath),
        exposureSecs: exposureSecs,
      );
    } catch (e) {
      if (!mounted) return;
      _logger.warning('Frame rejected: $e', source: 'LiveStackingNotifier');
      await _publishRejectionStats(
        generation,
        authority,
        e,
        filterKey:
            (filter != null && state.filterStacks.containsKey(targetFilter))
            ? targetFilter
            : null,
        sourceLabel: p.basename(imagePath),
        exposureSecs: exposureSecs,
      );
    }
  }

  Future<void> _startFilterSlotInRunningSession({
    required int generation,
    required Object authority,
    required LiveStackingService service,
    required String filterKey,
    required String referenceImagePath,
    double? exposureSecs,
  }) async {
    try {
      await service.startFromFileForFilter(
        filterKey: filterKey,
        referenceImagePath: referenceImagePath,
        config: state.config,
      );
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      final result = await service.getCurrentResultForFilter(filterKey);
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      final resolvedKey = normalizeLiveStackFilterKey(filterKey);
      final preview = _asUint16List(result.data);
      final totalPixels = result.width * result.height;
      final event =
          result.lastEvent ??
          LiveStackFrameEvent(
            sequenceIndex: 1,
            filterKey: resolvedKey,
            sourceLabel: p.basename(referenceImagePath),
            accepted: true,
            exposureSecs: exposureSecs,
            timestamp: DateTime.now().toUtc(),
          );
      final snapshot = FilterStackSnapshot(
        filterKey: resolvedKey,
        stats: result.stats,
        previewData: preview,
        previewWidth: result.width,
        previewHeight: result.height,
        channels: result.channels,
        lastFrameSigmaRejectedPixels: 0,
        lastFrameTotalPixels: totalPixels,
        referenceImagePath: referenceImagePath,
        revision: result.revision > 0 ? result.revision : 1,
        events: [event],
      );
      final updatedStacks = Map<String, FilterStackSnapshot>.of(
        state.filterStacks,
      )..[resolvedKey] = snapshot;
      final nextSelected = state.selectedFilterKey ?? resolvedKey;
      final selectedSnap = updatedStacks[nextSelected] ?? snapshot;
      state = _mirrorSelectedFilter(
        state.copyWith(
          filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
            updatedStacks,
          ),
          selectedFilterKey: nextSelected,
          frameLog: _prependEvent(state.frameLog, event),
          clearErrorMessage: true,
        ),
        selectedSnap,
      );
      _logger.info(
        'Started per-filter live stack for $resolvedKey from '
        '${p.basename(referenceImagePath)}',
        source: 'LiveStackingNotifier',
      );
    } catch (e) {
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      _logger.warning(
        'Could not start filter stack $filterKey from $referenceImagePath: $e',
        source: 'LiveStackingNotifier',
      );
      _recordLocalGateRejection(
        filterKey: filterKey,
        sourceLabel: p.basename(referenceImagePath),
        reason: userFacingError(e),
        exposureSecs: exposureSecs,
      );
    }
  }

  void _recordLocalGateRejection({
    required String filterKey,
    required String sourceLabel,
    required String reason,
    int detectedStars = 0,
    double? exposureSecs,
  }) {
    final existing = state.filterStacks[filterKey];
    final seq = (existing?.stats.totalFramesAttempted ?? 0) + 1;
    final event = LiveStackFrameEvent(
      sequenceIndex: seq,
      filterKey: filterKey,
      sourceLabel: sourceLabel,
      accepted: false,
      rejectionReason: reason,
      detectedStars: detectedStars,
      exposureSecs: exposureSecs,
      timestamp: DateTime.now().toUtc(),
    );
    _logger.info(
      'Live stack frame skipped ($filterKey): $reason',
      source: 'LiveStackingNotifier',
    );
    final updatedStacks = Map<String, FilterStackSnapshot>.of(
      state.filterStacks,
    );
    if (existing != null) {
      updatedStacks[filterKey] = existing.copyWith(
        events: _prependEvent(existing.events, event),
      );
    }
    state = state.copyWith(
      filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
        updatedStacks,
      ),
      frameLog: _prependEvent(state.frameLog, event),
    );
  }

  void _applyAcceptedResult({
    required LiveStackingResult result,
    required String fallbackFilterKey,
    required String sourceLabel,
    double? exposureSecs,
  }) {
    final resolvedKey = result.filterKey != kDefaultLiveStackFilterKey
        ? result.filterKey
        : fallbackFilterKey;
    final previousSnap = state.filterStacks[resolvedKey];
    final previousTotal =
        previousSnap?.stats.totalSigmaRejectedPixels ??
        state.stats.totalSigmaRejectedPixels;
    final newTotal = result.stats.totalSigmaRejectedPixels;
    final perFrameRejected = newTotal >= previousTotal
        ? newTotal - previousTotal
        : 0;
    final totalPixels = result.width * result.height;
    final preview = _asUint16List(result.data);
    final event =
        result.lastEvent ??
        LiveStackFrameEvent(
          sequenceIndex: result.stats.totalFramesAttempted,
          filterKey: resolvedKey,
          sourceLabel: sourceLabel,
          accepted: true,
          sigmaRejectedPixels: perFrameRejected,
          exposureSecs: exposureSecs,
          timestamp: DateTime.now().toUtc(),
        );
    final nextRevision = result.revision > 0
        ? result.revision
        : ((previousSnap?.revision ?? 0) + 1);
    final updatedSnap = FilterStackSnapshot(
      filterKey: resolvedKey,
      stats: result.stats,
      previewData: preview,
      previewWidth: result.width,
      previewHeight: result.height,
      channels: result.channels,
      lastFrameSigmaRejectedPixels: perFrameRejected,
      lastFrameTotalPixels: totalPixels,
      referenceImagePath:
          previousSnap?.referenceImagePath ?? state.referenceImagePath,
      revision: nextRevision,
      events: _prependEvent(previousSnap?.events ?? const [], event),
    );
    final updatedStacks = Map<String, FilterStackSnapshot>.of(
      state.filterStacks,
    )..[resolvedKey] = updatedSnap;
    final nextSelected = state.selectedFilterKey ?? resolvedKey;
    final selectedSnap = updatedStacks[nextSelected] ?? updatedSnap;

    state = _mirrorSelectedFilter(
      state.copyWith(
        filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
          updatedStacks,
        ),
        selectedFilterKey: nextSelected,
        frameLog: _prependEvent(state.frameLog, event),
      ),
      selectedSnap,
    );
  }

  /// Add a frame to the stack from raw pixel data carrying [pedestal] ADU.
  Future<void> addFrameFromData({
    required int width,
    required int height,
    required List<int> data,
    required double pedestal,
  }) {
    if (state.status != LiveStackingStatus.running) {
      return Future<void>.value();
    }
    final generation = _sessionGeneration;
    final authority = _sessionAuthority;
    if (authority == null) return Future<void>.value();

    return _enqueueIngest(() async {
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      final service = _sessionService;
      if (_remoteSessionBackend != null || service == null) return;
      final targetFilter =
          state.selectedFilterKey ?? kDefaultLiveStackFilterKey;
      try {
        final result = await service.addFrameFromData(
          width: width,
          height: height,
          data: data,
          pedestal: pedestal,
        );

        if (!_isCurrentSession(generation, authority) ||
            state.status != LiveStackingStatus.running) {
          return;
        }

        _applyAcceptedResult(
          result: result,
          fallbackFilterKey: targetFilter,
          sourceLabel: 'in-memory',
        );
      } catch (e) {
        if (!_isCurrentSession(generation, authority) ||
            state.status != LiveStackingStatus.running) {
          return;
        }
        _logger.warning('Frame rejected: $e', source: 'LiveStackingNotifier');
        await _publishRejectionStats(
          generation,
          authority,
          e,
          sourceLabel: 'in-memory',
        );
      }
    });
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
    Object error, {
    String? filterKey,
    String? sourceLabel,
    double? exposureSecs,
  }) async {
    if (!_isCurrentSession(generation, authority) ||
        state.status != LiveStackingStatus.running) {
      return;
    }
    LiveStackingStats? stats;
    if (error is LiveStackingFrameRejected) {
      stats = error.stats;
    } else {
      try {
        final remote = _remoteSessionBackend;
        stats = remote != null
            ? await remote.stackingGetStats()
            : (filterKey != null
                  ? await _sessionService?.getStatsForFilter(filterKey)
                  : await _sessionService?.getStats());
      } catch (e) {
        _logger.debug(
          'Live stacker rejection stats read failed: $e',
          source: 'LiveStackingNotifier',
        );
        return;
      }
    }
    if (stats == null) return;
    if (!_isCurrentSession(generation, authority) ||
        state.status != LiveStackingStatus.running) {
      return;
    }

    final resolvedKey =
        filterKey ?? state.selectedFilterKey ?? kDefaultLiveStackFilterKey;
    final rejEvent = LiveStackFrameEvent(
      sequenceIndex: stats.totalFramesAttempted,
      filterKey: resolvedKey,
      sourceLabel: sourceLabel ?? 'frame',
      accepted: false,
      rejectionReason: userFacingError(error),
      exposureSecs: exposureSecs,
      timestamp: DateTime.now().toUtc(),
    );

    final updatedStacks = Map<String, FilterStackSnapshot>.of(
      state.filterStacks,
    );
    final existing = updatedStacks[resolvedKey];
    if (existing != null) {
      updatedStacks[resolvedKey] = existing.copyWith(
        stats: stats,
        events: _prependEvent(existing.events, rejEvent),
      );
    }

    final shouldMirrorTopLevel =
        state.selectedFilterKey == null ||
        state.selectedFilterKey == resolvedKey;

    state = state.copyWith(
      stats: shouldMirrorTopLevel ? stats : state.stats,
      filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
        updatedStacks,
      ),
      frameLog: _prependEvent(state.frameLog, rejEvent),
    );
  }

  /// Update the stacking configuration.
  ///
  /// When a local stacking session is already running with active filter slots,
  /// runtime-mutable parameters (sigma clipping, alignment gates, star
  /// detection) are pushed straight to the native engine so they take effect on
  /// the very next frame without resetting accumulated pixels.
  void updateConfig(LiveStackingConfig config) {
    state = state.copyWith(config: config);
    final service = _sessionService;
    if (state.status == LiveStackingStatus.running &&
        _remoteSessionBackend == null &&
        service != null &&
        state.filterStacks.isNotEmpty) {
      unawaited(
        service.updateLiveConfig(config).catchError((Object e) {
          _logger.debug(
            'Live config update deferred: $e',
            source: 'LiveStackingNotifier',
          );
        }),
      );
    }
  }

  /// Reset one specific filter stack while preserving other active filters.
  Future<void> resetFilter(String filterKey) {
    final normalizedKey = normalizeLiveStackFilterKey(filterKey);
    if (state.status != LiveStackingStatus.running) {
      return Future<void>.value();
    }
    final authority = _sessionAuthority;
    if (authority == null) return Future<void>.value();
    final generation = _sessionGeneration;

    return _enqueueIngest(() async {
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      final existing = state.filterStacks[normalizedKey];
      if (existing == null) return;
      try {
        final remote = _remoteSessionBackend;
        final service = _sessionService;
        if (remote != null) {
          await remote.stackingReset(filterKey: normalizedKey);
        } else {
          await service!.resetForFilter(normalizedKey);
        }
        if (!_isCurrentSession(generation, authority)) return;
        final latest = state.filterStacks[normalizedKey] ?? existing;
        final cleared = latest.copyWith(
          stats: const LiveStackingStats(),
          clearPreviewData: true,
          previewWidth: 0,
          previewHeight: 0,
          lastFrameSigmaRejectedPixels: 0,
          lastFrameTotalPixels: 0,
          revision: latest.revision + 1,
          events: const [],
        );
        final updatedStacks = Map<String, FilterStackSnapshot>.of(
          state.filterStacks,
        )..[normalizedKey] = cleared;
        final nextState = state.copyWith(
          filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
            updatedStacks,
          ),
          frameLog: state.frameLog
              .where((e) => e.filterKey != normalizedKey)
              .toList(growable: false),
        );
        state = state.selectedFilterKey == normalizedKey
            ? _mirrorSelectedFilter(nextState, cleared)
            : nextState;
      } catch (e) {
        if (!_isCurrentSession(generation, authority)) return;
        state = state.copyWith(
          errorMessage:
              'Failed to reset $normalizedKey stack: ${userFacingError(e)}',
        );
      }
    });
  }

  /// Stop and release a single filter stack. If it was the last remaining
  /// filter, stops the entire session cleanly.
  Future<void> stopFilter(String filterKey) async {
    final normalizedKey = normalizeLiveStackFilterKey(filterKey);
    if (!state.filterStacks.containsKey(normalizedKey)) return;
    if (state.filterStacks.length <= 1) {
      await stop();
      return;
    }
    final authority = _sessionAuthority;
    if (authority == null) return;
    final generation = _sessionGeneration;
    var stopWholeSession = false;

    await _enqueueIngest(() async {
      if (!_isCurrentSession(generation, authority)) return;
      if (!state.filterStacks.containsKey(normalizedKey)) return;
      if (state.filterStacks.length <= 1) {
        stopWholeSession = true;
        return;
      }
      try {
        final remote = _remoteSessionBackend;
        final service = _sessionService;
        if (remote != null) {
          await remote.stackingStop(filterKey: normalizedKey);
        } else if (service != null) {
          await service.stopForFilter(normalizedKey);
        }
        if (!_isCurrentSession(generation, authority)) return;
        final updatedStacks = Map<String, FilterStackSnapshot>.of(
          state.filterStacks,
        )..remove(normalizedKey);
        if (updatedStacks.isEmpty) {
          stopWholeSession = true;
          return;
        }
        final remainingKeys = updatedStacks.keys.toList()
          ..sort(compareLiveStackFilters);
        final nextSelected = state.selectedFilterKey == normalizedKey
            ? remainingKeys.first
            : (state.selectedFilterKey ?? remainingKeys.first);
        final selectedSnap = updatedStacks[nextSelected]!;
        state = _mirrorSelectedFilter(
          state.copyWith(
            filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(
              updatedStacks,
            ),
            selectedFilterKey: nextSelected,
            frameLog: state.frameLog
                .where((e) => e.filterKey != normalizedKey)
                .toList(growable: false),
          ),
          selectedSnap,
        );
      } catch (e) {
        if (!_isCurrentSession(generation, authority)) return;
        state = state.copyWith(
          errorMessage:
              'Failed to stop $normalizedKey stack: ${userFacingError(e)}',
        );
      }
    });
    if (stopWholeSession) {
      await stop();
    }
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
    try {
      await _ingestChain;
    } catch (e) {
      _logger.debug(
        'Live stack ingest settled with error before lifecycle operation: $e',
        source: 'LiveStackingNotifier',
      );
    }
    final authority = _sessionAuthority;
    if (authority == null || state.status != LiveStackingStatus.running) return;
    final generation = ++_sessionGeneration;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    try {
      final remote = _remoteSessionBackend;
      final service = _sessionService;
      final existingFilterKeys = state.filterStacks.keys.toList(
        growable: false,
      );
      final hasNamedFilter = existingFilterKeys.any(
        (key) => key != kDefaultLiveStackFilterKey,
      );
      if (remote != null) {
        await remote.stackingReset();
      } else if (existingFilterKeys.length > 1 || hasNamedFilter) {
        for (final key in existingFilterKeys) {
          await service!.resetForFilter(key);
        }
      } else {
        await service!.reset();
      }
      if (!_isCurrentSession(generation, authority)) return;
      // Rebuild from scratch (preserving config) so per-frame counters and the
      // old reference identity drop alongside the cleared cumulative stats.
      state = LiveStackingState(
        status: state.status,
        isArmed: state.isArmed,
        config: state.config,
      );
      if (remote != null) _startRemotePolling(generation, authority);
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      _logger.error(
        'Failed to reset stacker: $e',
        source: 'LiveStackingNotifier',
      );
      state = state.copyWith(
        errorMessage: 'Failed to reset stack: ${userFacingError(e)}',
      );
      final remote = _remoteSessionBackend;
      if (remote != null) _startRemotePolling(generation, authority);
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
      // A Stop racing Start or an in-flight frame ingest must be ordered after
      // both settle; otherwise Start/ingest can create a native stacker after
      // Stop runs or Stop can skip releasing it.
      final starting = _startInFlight;
      if (starting != null) await starting;
      try {
        await _ingestChain;
      } catch (_) {
        // Ingest errors are owned by their callers.
      }
      if (remote != null) {
        await remote.stackingStop();
      } else if (service != null) {
        await service.stop();
      }
    } catch (e) {
      // An armed session that never received a frame has no native slot.
      // api_stacking_stop reports that as "not initialized". The stop still
      // succeeded: the in-flight start/ingest above was waited out, and
      // nothing was ever started. Any other failure leaves the session up.
      if (!_stopFoundNoStack(e)) {
        _logger.error(
          'Failed to stop stacker: $e',
          source: 'LiveStackingNotifier',
        );
        if (mounted &&
            generation == _sessionGeneration &&
            identical(authority, _sessionAuthority)) {
          state = state.copyWith(
            errorMessage: 'Failed to stop stack: ${userFacingError(e)}',
          );
          if (remote != null &&
              authority != null &&
              state.status == LiveStackingStatus.running) {
            _startRemotePolling(generation, authority);
          }
        }
        return;
      }
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

final liveStackingProvider =
    StateNotifierProvider<LiveStackingNotifier, LiveStackingState>((ref) {
      return LiveStackingNotifier(ref);
    });
