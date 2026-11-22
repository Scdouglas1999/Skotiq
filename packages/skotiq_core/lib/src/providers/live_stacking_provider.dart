import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'async_scope.dart';
import '../errors/error_text.dart';
import '../backend/skotiq_backend.dart';
import '../services/live_stacking_service.dart';
import '../utils/logging_service.dart';
import '../utils/poll_pace.dart';
import 'backend_provider.dart';
import 'live_stacking_service_provider.dart';
import 'logging_service_provider.dart';
import '../models/imaging/live_stacking_models.dart';
import '../models/imaging/live_stacking_state.dart';

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
      final session = _sessionService;
      final localService = session != null && !session.readsHost
          ? session
          : null;
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

  /// On a linked client, fetches the viewed slot's pixels again after a
  /// failed fetch. Null while nothing failed.
  Timer? _fetchRetryTimer;

  /// Consecutive failed fetches of the host's pixels. Flips to error once
  /// sustained (not on a single transient blip).
  int _consecutiveFetchFailures = 0;

  /// Monotonically identifies the currently displayed stacking session.
  /// Cancelling a timer cannot cancel an HTTP/FFI Future already in flight, so
  /// every completion also checks this generation and its backend authority.
  int _sessionGeneration = 0;
  SkotiqBackend? _sessionAuthority;
  LiveStackingService? _sessionService;

  /// Whether this session's stack is the linked host's.
  bool get _sessionOnHost {
    final service = _sessionService;
    return service != null && service.readsHost;
  }

  /// On a linked client, the pixel revision of each slot of the host's stack
  /// as the host's runtime channel last described it. Null until the channel
  /// has described a stack; nothing is fetched before.
  Map<String, int>? _hostRevisions;

  bool _fetchInFlight = false;
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
    _hostRevisions = null;
    _sessionGeneration++;
    _cancelFetchRetry();
    _fetchInFlight = false;
    _consecutiveFetchFailures = 0;
    _sessionAuthority = null;
    _sessionService = null;
  }

  void _cancelFetchRetry() {
    _fetchRetryTimer?.cancel();
    _fetchRetryTimer = null;
  }

  Future<void> _trackStart(Future<void> Function() operation) {
    final active = _startInFlight;
    if (active != null) return active;
    final future = operation();
    _startInFlight = future;
    // The caller receives the outcome; this bookkeeping copy must not report
    // a failure a second time as unhandled.
    future.whenComplete(() {
      if (identical(_startInFlight, future)) _startInFlight = null;
    }).ignore();
    return future;
  }

  /// Arm host-side live stacking. The host's runtime channel then describes
  /// its stack and this client fetches each new revision of the viewed slot.
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
    final service = _service;
    if (!service.readsHost) {
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
    _sessionService = service;
    _consecutiveFetchFailures = 0;
    state = LiveStackingState(
      status: LiveStackingStatus.running,
      isArmed: true,
      config: effectiveConfig,
    );
    try {
      final stats = await service.start(config: effectiveConfig);
      if (!_isCurrentSession(generation, backend)) return;
      state = state.copyWith(stats: stats);
      _logger.info(
        'Remote live stacking armed on host',
        source: 'LiveStackingNotifier',
      );
      unawaited(_fetchHostSlot(generation, backend));
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

  /// Fetch the pixels of the viewed slot of the host's stack when the
  /// host's channel says they changed since this client last showed them,
  /// and again after the download while they keep changing. A failed fetch
  /// is retried after a pause; the third failure in a row is shown and the
  /// retries stop ([retryHostFetch] starts them again).
  Future<void> _fetchHostSlot(int generation, SkotiqBackend backend) async {
    final service = _sessionService;
    if (service == null ||
        !service.readsHost ||
        _fetchInFlight ||
        !_isCurrentSession(generation, backend) ||
        state.status != LiveStackingStatus.running) {
      return;
    }
    final slotKey = state.viewedFilterKey;
    final slotRevision = _hostRevisions?[slotKey];
    final shown = state.filterStacks[slotKey];
    if (slotRevision == null ||
        shown == null ||
        (shown.hasPixels && shown.revision == slotRevision)) {
      _cancelFetchRetry();
      return;
    }
    _cancelFetchRetry();
    _fetchInFlight = true;
    try {
      final result = await service.getCurrentResult(filterKey: slotKey);
      _fetchInFlight = false;
      if (!_isCurrentSession(generation, backend) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      _consecutiveFetchFailures = 0;
      _showHostSlot(slotKey, slotRevision, result);
    } catch (e) {
      _fetchInFlight = false;
      if (!_isCurrentSession(generation, backend) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      _consecutiveFetchFailures++;
      if (_consecutiveFetchFailures >= 3) {
        _logger.error(
          'Lost contact with host stacker: $e',
          source: 'LiveStackingNotifier',
        );
        // The host may still be stacking. Keep the session active so Stop is
        // available, but make the stale preview failure explicit and retryable.
        state = state.copyWith(errorMessage: 'Lost contact with host stacker');
        return;
      }
      _fetchRetryTimer = Timer(
        PollPace.stretch(const Duration(milliseconds: 2500)),
        () => unawaited(_fetchHostSlot(generation, backend)),
      );
      return;
    }
    if (state.viewedFilterKey != slotKey ||
        _hostRevisions?[slotKey] != slotRevision) {
      await _fetchHostSlot(generation, backend);
    }
  }

  /// The host's live stack as the host's runtime channel describes it, on a
  /// linked client. A stack the host runs, whoever armed it, is shown here
  /// and can be reset or stopped from here. When the host's stack ends, this
  /// client's view of it ends too; nothing is sent back to the host.
  void applyHostStack(LiveStackSummary? host, SkotiqBackend backend) {
    final service = _service;
    if (!service.readsHost) return;
    _hostRevisions = host == null
        ? null
        : {for (final slot in host.slots) slot.filterKey: slot.revision};
    // This client's own start or stop is settling; the host's next update
    // describes its outcome.
    if (_startInFlight != null || _stopInFlight != null) return;
    final onThisHost =
        state.status == LiveStackingStatus.running &&
        _sessionOnHost &&
        identical(_sessionAuthority, backend);
    if (host == null) {
      if (!onThisHost) return;
      _invalidateSession();
      state = LiveStackingState(config: state.config);
      return;
    }
    if (!onThisHost) {
      ++_sessionGeneration;
      _sessionAuthority = backend;
      _sessionService = service;
      _consecutiveFetchFailures = 0;
      state = LiveStackingState(
        status: LiveStackingStatus.running,
        isArmed: host.armed,
        config: state.config,
      );
    }
    final stacks = <String, FilterStackSnapshot>{
      for (final slot in host.slots)
        slot.filterKey:
            (state.filterStacks[slot.filterKey] ??
                    FilterStackSnapshot(filterKey: slot.filterKey))
                .copyWith(stats: slot.stats, channels: slot.channels),
    };
    final keys = stacks.keys.toList()..sort(compareLiveStackFilters);
    final selected = stacks.containsKey(state.selectedFilterKey)
        ? state.selectedFilterKey
        : keys.firstOrNull;
    final next = state.copyWith(
      isArmed: host.armed,
      filterStacks: Map<String, FilterStackSnapshot>.unmodifiable(stacks),
      frameLog: state.frameLog
          .where((e) => stacks.containsKey(e.filterKey))
          .toList(growable: false),
    );
    state = selected == null
        ? LiveStackingState(
            status: next.status,
            isArmed: next.isArmed,
            config: next.config,
          )
        : _mirrorSelectedFilter(next, stacks[selected]!);
    final authority = _sessionAuthority;
    if (authority != null) {
      unawaited(_fetchHostSlot(_sessionGeneration, authority));
    }
  }

  /// Show [result], the pixels of the host's [slotKey] at [revision].
  void _showHostSlot(String slotKey, int revision, LiveStackingResult result) {
    final known = state.filterStacks[slotKey];
    if (known == null) return;
    final snapshot = known.copyWith(
      stats: result.stats,
      previewData: _asUint16List(result.data),
      previewWidth: result.width,
      previewHeight: result.height,
      channels: result.channels,
      lastFrameTotalPixels: result.width * result.height,
      revision: revision,
    );
    final next = state.copyWith(
      filterStacks: Map<String, FilterStackSnapshot>.unmodifiable({
        ...state.filterStacks,
        slotKey: snapshot,
      }),
      clearErrorMessage: true,
    );
    state = next.viewedFilterKey == slotKey
        ? _mirrorSelectedFilter(next, snapshot)
        : next;
  }

  /// Fetch the host's pixels again after they could not be fetched, without
  /// restarting the host stack.
  void retryHostFetch() {
    final service = _sessionService;
    final authority = _sessionAuthority;
    if (service == null ||
        !service.readsHost ||
        authority == null ||
        state.status != LiveStackingStatus.running ||
        !identical(service, _ref.read(liveStackingServiceProvider)) ||
        _ref.backendScopeOver(authority).isStale) {
      return;
    }
    _consecutiveFetchFailures = 0;
    state = state.copyWith(clearErrorMessage: true);
    unawaited(_fetchHostSlot(_sessionGeneration, authority));
  }

  /// Arm live stacking to automatically stack incoming captured frames without
  /// requiring the user to pick a reference file up front.
  ///
  /// On a remote connection, delegates to [startRemote]. Locally, arms the
  /// session in memory so the next frame captured (manual or sequenced) starts
  /// its filter's stack automatically.
  Future<void> arm({LiveStackingConfig? config}) {
    if (_service.readsHost) {
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
    final authority = _sessionAuthority;
    if (_sessionOnHost && authority != null) {
      unawaited(_fetchHostSlot(_sessionGeneration, authority));
    }
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

  /// [startFromFile], or [startFromFileForFilter] with a [filterKey], for a
  /// caller that answers with the outcome: a failure is recorded in the state
  /// as usual and also completes the returned future with the stacker's error.
  Future<void> startFromFileOrThrow(
    String referenceImagePath, {
    String? filterKey,
    LiveStackingConfig? config,
  }) {
    return _trackStart(
      () => _startFromFile(
        referenceImagePath,
        config: config,
        filterKey: filterKey,
        throwOnFailure: true,
      ),
    );
  }

  Future<void> _startFromFile(
    String referenceImagePath, {
    LiveStackingConfig? config,
    String? filterKey,
    bool throwOnFailure = false,
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
    final LiveStackingService service;

    if (isAlreadyRunningOnAuthority) {
      generation = _sessionGeneration;
      effectiveConfig = config ?? state.config;
      service = _sessionService ?? _service;
    } else {
      generation = ++_sessionGeneration;
      _sessionAuthority = authority;
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
      final stats = await service.start(
        referenceImagePath: referenceImagePath,
        config: effectiveConfig,
        filterKey: normalizedFilter,
      );

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
      final result = await service.getCurrentResult(
        filterKey: normalizedFilter,
      );
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
      if (throwOnFailure) rethrow;
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
      final stats = await service.startFromData(
        width: width,
        height: height,
        data: data,
        pedestal: pedestal,
        config: effectiveConfig,
        filterKey: normalizedFilter,
      );

      if (!_isCurrentSession(generation, authority)) return;

      if (!isAlreadyRunningOnAuthority) {
        state = state.copyWith(stats: stats);
      }

      // Mirror startFromFile: surface the reference frame as the initial
      // preview so the panel and any auto-feed broadcast have an image
      // immediately rather than only after the second frame.
      final result = await service.getCurrentResult(
        filterKey: normalizedFilter,
      );
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
  ///
  /// With [propagate] a failing step completes its caller with the error
  /// instead of being logged here.
  Future<void> _enqueueIngest(
    Future<void> Function() body, {
    bool propagate = false,
  }) {
    final completer = Completer<void>();
    final settled = _ingestChain.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final done = settled.then((_) async {
      try {
        await body();
      } catch (error, stackTrace) {
        if (propagate) {
          completer.completeError(error, stackTrace);
          return;
        }
        _logger.error(
          'Live stack ingest step failed: ${_stackErrorText(error)}',
          source: 'LiveStackingNotifier',
        );
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    _ingestChain = done;
    return completer.future;
  }

  String _stackErrorText(Object error) {
    try {
      return error.toString();
    } catch (_) {
      // Driver exceptions may fail while formatting their own details.
      return Error.safeToString(error);
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

  /// Add [imagePath] to the active slot of a running stack and return the
  /// stacked result, for a caller that answers with the outcome. A frame the
  /// stacker refuses is recorded in the state as usual and also completes the
  /// returned future with the stacker's error.
  Future<LiveStackingResult> addFrameFromFileOrThrow(String imagePath) async {
    final generation = _sessionGeneration;
    final authority = _sessionAuthority;
    if (state.status != LiveStackingStatus.running || authority == null) {
      throw StateError('Live stacker not initialized');
    }
    LiveStackingResult? added;
    await _enqueueIngest(() async {
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      added = await _ingestFrameFromFileWithMetadata(
        imagePath,
        generation: generation,
        authority: authority,
        throwOnFailure: true,
      );
    }, propagate: true);
    final result = added;
    if (result == null) {
      throw StateError('Live stacking stopped before $imagePath was added');
    }
    return result;
  }

  /// The stacked result after [imagePath] joined it; null when the frame was
  /// skipped, started a new filter slot, or the session ended meanwhile.
  Future<LiveStackingResult?> _ingestFrameFromFileWithMetadata(
    String imagePath, {
    required int generation,
    required Object authority,
    String? filter,
    double? exposureSecs,
    double? hfr,
    int? starCount,
    bool throwOnFailure = false,
  }) async {
    if (state.status != LiveStackingStatus.running) return null;

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
        detectedStars: starCount,
        exposureSecs: exposureSecs,
      );
      return null;
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
      return null;
    }

    final service = _sessionService;
    final onHost = _sessionOnHost;

    // If locally armed (no stack yet) OR a brand-new filter arrived while
    // `separateByFilter` is active, initialize that filter's stack with this
    // frame as its reference!
    final needsNewFilterStack =
        !onHost &&
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
      return null;
    }

    try {
      final useExplicitFilter =
          !onHost &&
          filter != null &&
          state.filterStacks.containsKey(targetFilter);
      final result = await service!.addFrameFromFile(
        imagePath,
        filterKey: useExplicitFilter ? targetFilter : null,
      );

      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return null;
      }

      _applyAcceptedResult(
        result: result,
        fallbackFilterKey: targetFilter,
        sourceLabel: p.basename(imagePath),
        exposureSecs: exposureSecs,
      );
      return result;
    } catch (e) {
      if (!mounted) return null;
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
      if (throwOnFailure) rethrow;
      return null;
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
      await service.start(
        referenceImagePath: referenceImagePath,
        config: state.config,
        filterKey: filterKey,
      );
      if (!_isCurrentSession(generation, authority) ||
          state.status != LiveStackingStatus.running) {
        return;
      }
      final result = await service.getCurrentResult(filterKey: filterKey);
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
    int? detectedStars,
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
      if (service == null || service.readsHost) return;
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
        stats = await _sessionService?.getStats(filterKey: filterKey);
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
        service != null &&
        !service.readsHost &&
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
  ///
  /// With [throwOnFailure] a failure also completes the returned future with
  /// the stacker's error.
  Future<void> resetFilter(String filterKey, {bool throwOnFailure = false}) {
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
        await _sessionService!.reset(filterKey: normalizedKey);
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
        if (throwOnFailure) rethrow;
      }
    }, propagate: throwOnFailure);
  }

  /// Stop and release a single filter stack. If it was the last remaining
  /// filter, stops the entire session cleanly.
  ///
  /// With [throwOnFailure] a failure also completes the returned future with
  /// the stacker's error.
  Future<void> stopFilter(
    String filterKey, {
    bool throwOnFailure = false,
  }) async {
    final normalizedKey = normalizeLiveStackFilterKey(filterKey);
    if (!state.filterStacks.containsKey(normalizedKey)) return;
    if (!_sessionOnHost && state.filterStacks.length <= 1) {
      await (throwOnFailure ? stopOrThrow() : stop());
      return;
    }
    final authority = _sessionAuthority;
    if (authority == null) return;
    final generation = _sessionGeneration;
    var stopWholeSession = false;

    await _enqueueIngest(() async {
      if (!_isCurrentSession(generation, authority)) return;
      if (!state.filterStacks.containsKey(normalizedKey)) return;
      if (!_sessionOnHost && state.filterStacks.length <= 1) {
        stopWholeSession = true;
        return;
      }
      try {
        await _sessionService?.stop(filterKey: normalizedKey);
        if (!_isCurrentSession(generation, authority)) return;
        final updatedStacks = Map<String, FilterStackSnapshot>.of(
          state.filterStacks,
        )..remove(normalizedKey);
        if (updatedStacks.isEmpty) {
          // A linked viewer can know fewer slots than its host. Its final
          // named stop ends this view without releasing any other host slot.
          _invalidateSession();
          state = LiveStackingState(config: state.config);
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
        if (throwOnFailure) rethrow;
      }
    }, propagate: throwOnFailure);
    if (stopWholeSession) {
      await (throwOnFailure ? stopOrThrow() : stop());
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
    _cancelFetchRetry();
    try {
      final service = _sessionService!;
      final onHost = service.readsHost;
      final existingFilterKeys = state.filterStacks.keys.toList(
        growable: false,
      );
      final hasNamedFilter = existingFilterKeys.any(
        (key) => key != kDefaultLiveStackFilterKey,
      );
      if (onHost) {
        await service.reset();
      } else if (existingFilterKeys.length > 1 || hasNamedFilter) {
        for (final key in existingFilterKeys) {
          await service.reset(filterKey: key);
        }
      } else {
        await service.reset();
      }
      if (!_isCurrentSession(generation, authority)) return;
      // Rebuild from scratch (preserving config) so per-frame counters and the
      // old reference identity drop alongside the cleared cumulative stats.
      state = LiveStackingState(
        status: state.status,
        isArmed: state.isArmed,
        config: state.config,
      );
      if (onHost) unawaited(_fetchHostSlot(generation, authority));
    } catch (e) {
      if (!_isCurrentSession(generation, authority)) return;
      _logger.error(
        'Failed to reset stacker: $e',
        source: 'LiveStackingNotifier',
      );
      state = state.copyWith(
        errorMessage: 'Failed to reset stack: ${userFacingError(e)}',
      );
      if (_sessionOnHost) unawaited(_fetchHostSlot(generation, authority));
    }
  }

  /// Stop stacking and release resources.
  Future<void> stop() => _trackStop(throwOnFailure: false);

  /// [stop] for a caller that answers with the outcome: a failure other than
  /// "nothing was started" also completes the returned future with the
  /// stacker's error. A stop already in flight is joined as it is.
  Future<void> stopOrThrow() => _trackStop(throwOnFailure: true);

  Future<void> _trackStop({required bool throwOnFailure}) {
    final active = _stopInFlight;
    if (active != null) return active;
    final future = _stop(throwOnFailure: throwOnFailure);
    _stopInFlight = future;
    // The caller receives the outcome; this bookkeeping copy must not report
    // a failure a second time as unhandled.
    future.whenComplete(() {
      if (identical(_stopInFlight, future)) _stopInFlight = null;
    }).ignore();
    return future;
  }

  Future<void> _stop({required bool throwOnFailure}) async {
    final config = state.config;
    final authority = _sessionAuthority ?? _ref.read(backendProvider);
    final service = _sessionService;
    final onHost = _sessionOnHost;
    final generation = ++_sessionGeneration;
    _cancelFetchRetry();
    _fetchInFlight = false;
    _consecutiveFetchFailures = 0;
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
      await service?.stop();
    } catch (e, stackTrace) {
      // An armed session that never received a frame has no native slot.
      // api_stacking_stop reports that as "not initialized". The stop still
      // succeeded: the in-flight start/ingest above was waited out, and
      // nothing was ever started. Any other failure leaves the session up.
      final message = _stackErrorText(e);
      if (!message.toLowerCase().contains('live stacker not initialized')) {
        _logger.error(
          'Failed to stop stacker: $message',
          source: 'LiveStackingNotifier',
        );
        if (mounted &&
            generation == _sessionGeneration &&
            identical(authority, _sessionAuthority)) {
          state = state.copyWith(
            errorMessage: 'Failed to stop stack: ${userFacingError(e)}',
          );
          if (onHost &&
              authority != null &&
              state.status == LiveStackingStatus.running) {
            unawaited(_fetchHostSlot(generation, authority));
          }
        }
        if (throwOnFailure) Error.throwWithStackTrace(e, stackTrace);
        return;
      }
    }

    if (!mounted || generation != _sessionGeneration) return;
    _sessionAuthority = null;
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
