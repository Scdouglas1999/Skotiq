// Mobile session replay scrubber.
//
// This provider owns the state machine that powers the mobile
// "replay a past session" screen: a single sequence-run id, an
// in-memory merged timeline of events + frame markers, a playhead
// position, and a derived `ReplaySnapshot` stream the UI binds to.
//
// Architecture:
//   * The notifier is created with a runId. On construction it kicks
//     off three concurrent fetches — run header, frames page, events
//     page — against the active NetworkBackend (the local FfiBackend
//     cannot resolve these because the desktop already renders runs
//     directly from its Drift DB; the replay surface is phone-only).
//   * Once the fetches resolve the timeline is materialised: every
//     event becomes a `ReplayMarker.event`, every frame becomes a
//     `ReplayMarker.frame`, and the merged list is sorted by
//     `timestampMs` ascending. This sorted list is the source of truth
//     for everything else.
//   * The playhead is an offset (in ms) from the run's `startedAt`.
//     `seekTo(ms)` clamps to [0, durationMs] and updates the state;
//     `play()` schedules a periodic ticker that advances the playhead
//     at the configured `playbackSpeed`.
//   * `snapshotStream` derives a `ReplaySnapshot` from the markers at
//     or before the playhead. Implemented as a `BehaviorSubject`-style
//     broadcast controller so the widget can `StreamBuilder` it
//     without re-running the scan on every rebuild.
//
// The notifier is intentionally implementation-agnostic about the
// backend: tests inject a `SessionReplayDataSource` that returns
// canned data. Production wiring constructs the data source from the
// app's `NetworkBackend` at the screen layer (see the mobile
// `session_replay_screen.dart`).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';

/// One playhead-positioned snapshot of "what the dashboard would have
/// shown at this moment". Built by [SessionReplayNotifier] by scanning
/// the merged timeline up to the current playhead.
class ReplaySnapshot {
  /// Cursor time relative to the run's `startedAt`, in milliseconds.
  final int playheadMs;

  /// Absolute wall-clock time at the playhead (startedAt + playheadMs).
  final DateTime playheadWallClock;

  /// Most-recent target name observed in any event whose data block
  /// carried one. Falls back to the run's `targetName` if no event
  /// has supplied a value at or before the playhead.
  final String? currentTarget;

  /// Most-recent current-node observation. Sourced from sequencer
  /// progress events; null until the first such event lands.
  final String? currentNodeName;

  /// Most-recent filter name observed on a captured frame.
  final String? currentFilter;

  /// Number of frames captured at or before the playhead.
  final int frameCount;

  /// Most-recent HFR observed on a captured frame.
  final double? lastHfr;

  /// Most-recent guiding total RMS observed on a captured frame
  /// (frames carry the RMS sample that was current during the
  /// exposure). For events-only guidance updates we'd need the
  /// guide-RMS history endpoint — wired separately by callers.
  final double? lastGuideRmsTotal;

  /// Most-recent recovery state observed in events of type
  /// `recovery.entered` / `recovery.completed`. Null when no
  /// recovery activity has been recorded at the playhead.
  final String? recoveryState;

  /// All markers (events + frames) at or before the playhead, in
  /// timestamp order. Used by the UI to render a scrollable event
  /// log alongside the scrubber.
  final List<ReplayMarker> markersUpToPlayhead;

  /// All markers from the timeline regardless of playhead position.
  /// Used to render the timeline ticks (the ticks themselves are
  /// always visible; only their "passed" highlight depends on the
  /// playhead).
  final List<ReplayMarker> allMarkers;

  const ReplaySnapshot({
    required this.playheadMs,
    required this.playheadWallClock,
    required this.frameCount,
    required this.markersUpToPlayhead,
    required this.allMarkers,
    this.currentTarget,
    this.currentNodeName,
    this.currentFilter,
    this.lastHfr,
    this.lastGuideRmsTotal,
    this.recoveryState,
  });
}

/// A single tick on the replay timeline. Tagged-union: either an
/// event drawn from the LoggingService ring buffer, or a captured
/// frame drawn from the producing_run_id-scoped images query.
sealed class ReplayMarker {
  /// Millisecond timestamp relative to the run's `startedAt`. Used
  /// for layout (x-axis position) and for the scan-to-time projection.
  int get offsetMs;

  /// Absolute wall-clock timestamp. Used for tooltips and for
  /// matching the cursor position to displayed clock times.
  DateTime get wallClock;
}

/// Event marker — drawn as a vertical tick on the timeline. Colour
/// depends on `severity`.
class ReplayEventMarker implements ReplayMarker {
  @override
  final int offsetMs;

  @override
  final DateTime wallClock;

  /// Severity name (`info` | `warning` | `error` | `critical` | `debug`).
  /// The widget maps this to a colour token via [SkotiqColors].
  final String severity;

  /// Source/category tag (e.g. `Sequencer`, `Guiding`, `Imaging`).
  final String? source;

  /// Free-form message body. Multi-line entries are truncated for
  /// display but kept intact in the data layer for the tooltip.
  final String message;

  /// Structured fields the original log entry carried, when any.
  /// Recovery events stash `{state: 'entering' | 'completed'}` here.
  final Map<String, dynamic>? fields;

  const ReplayEventMarker({
    required this.offsetMs,
    required this.wallClock,
    required this.severity,
    required this.message,
    this.source,
    this.fields,
  });

  /// Build a marker from a wire event using the run's `startedAt`
  /// as the offset anchor. Wire events carry a `timestampMs` so
  /// the projection is monotonic without any DateTime arithmetic.
  factory ReplayEventMarker.fromRemote(RemoteReplayEvent e, int runStartedMs) {
    return ReplayEventMarker(
      offsetMs: e.timestampMs - runStartedMs,
      wallClock: e.timestamp,
      severity: e.severity,
      source: e.source,
      message: e.message,
      fields: e.fields,
    );
  }
}

/// Frame marker — drawn as a small triangle/diamond below the event
/// row. Tap opens the per-frame detail sheet.
class ReplayFrameMarker implements ReplayMarker {
  @override
  final int offsetMs;

  @override
  final DateTime wallClock;

  /// Captured-image database id. Used to build the thumbnail URL.
  final int frameId;

  /// Filter name at the time of the exposure (may be null for
  /// filterless cameras).
  final String? filter;

  /// HFR measurement when the frame was graded. Null if unmeasured.
  final double? hfr;

  /// Total guiding RMS during the exposure. Null when guiding was
  /// not running.
  final double? guideRmsTotal;

  /// Exposure duration in seconds.
  final double exposureSecs;

  /// `light` | `dark` | `flat` | `bias`. Frame-type ticks share the
  /// same row but the tooltip differentiates.
  final String frameType;

  /// Whether the grader accepted this frame. Rejected frames get a
  /// muted colour in the timeline.
  final bool isAccepted;

  const ReplayFrameMarker({
    required this.offsetMs,
    required this.wallClock,
    required this.frameId,
    required this.exposureSecs,
    required this.frameType,
    required this.isAccepted,
    this.filter,
    this.hfr,
    this.guideRmsTotal,
  });

  factory ReplayFrameMarker.fromRemote(RemoteReplayFrame f, int runStartedMs) {
    return ReplayFrameMarker(
      offsetMs: f.capturedAtMs - runStartedMs,
      wallClock: f.capturedAt,
      frameId: f.id,
      filter: f.filter,
      hfr: f.hfr,
      guideRmsTotal: f.guidingRmsTotal,
      exposureSecs: f.exposureDuration,
      frameType: f.frameType,
      isAccepted: f.isAccepted,
    );
  }
}

/// Top-level state for the replay screen. Modelled as a sealed
/// hierarchy so the UI can pattern-match cleanly without an
/// `isLoading` + `hasError` + `data` triple-state.
sealed class SessionReplayState {
  const SessionReplayState();
}

class SessionReplayLoading extends SessionReplayState {
  final int runId;
  const SessionReplayLoading(this.runId);
}

class SessionReplayError extends SessionReplayState {
  final int runId;
  final String message;
  final Object cause;
  const SessionReplayError({
    required this.runId,
    required this.message,
    required this.cause,
  });
}

class SessionReplayReady extends SessionReplayState {
  final int runId;
  final RemoteSequenceRunDetail run;
  final List<ReplayMarker> markers;
  final int durationMs;
  final int playheadMs;
  final bool isPlaying;

  /// Playback rate. 1.0 = real-time. 4x and 16x are the common
  /// "fast-forward to see what happened" presets; anything higher
  /// loses fidelity (the ticker runs at 30 Hz so >30x skips frames).
  final double playbackSpeed;

  /// True when the events list is known-incomplete (server signal
  /// from `is_partial`). The UI renders a "Event history truncated"
  /// banner so the operator knows the gaps are by design.
  final bool eventsPartial;

  /// Server-reported reason for the truncation, when known. Currently
  /// `no_buffered_entries` or `ring_buffer_truncated`.
  final String? eventsPartialReason;

  const SessionReplayReady({
    required this.runId,
    required this.run,
    required this.markers,
    required this.durationMs,
    required this.playheadMs,
    required this.isPlaying,
    required this.playbackSpeed,
    required this.eventsPartial,
    this.eventsPartialReason,
  });

  SessionReplayReady copyWith({
    int? playheadMs,
    bool? isPlaying,
    double? playbackSpeed,
  }) {
    return SessionReplayReady(
      runId: runId,
      run: run,
      markers: markers,
      durationMs: durationMs,
      playheadMs: playheadMs ?? this.playheadMs,
      isPlaying: isPlaying ?? this.isPlaying,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      eventsPartial: eventsPartial,
      eventsPartialReason: eventsPartialReason,
    );
  }
}

/// Backend boundary the notifier reads from. Production wiring binds
/// this to a [NetworkBackend]; tests inject a stub so the notifier's
/// scan-to-time logic can be exercised without HTTP plumbing.
abstract class SessionReplayDataSource {
  /// Resolve the run header. Used to derive the duration and to
  /// power the timeline header label.
  Future<RemoteSequenceRunDetail> fetchRun(int runId);

  /// Fetch ALL events captured during the run's window. Pages
  /// transparently — the notifier asks for "everything" and lets
  /// this implementation handle the cursor walk.
  Future<RemoteReplayEventsPage> fetchEvents(int runId);

  /// Fetch ALL frames produced by the run.
  Future<List<RemoteReplayFrame>> fetchFrames(int runId);
}

/// Default [SessionReplayDataSource] backed by an HTTP
/// [NetworkBackend]. The pagination loops are bounded by the
/// server-side cap (1000 rows per page) so even a multi-thousand-
/// frame all-night run completes in a handful of round-trips.
class NetworkSessionReplayDataSource implements SessionReplayDataSource {
  final NetworkBackend backend;

  /// Per-page size for the fetch loops. Matches the server's
  /// default + max so we don't overshoot the clamp.
  final int pageSize;

  /// Hard ceiling on the number of pages we fetch. Anti-DOS for the
  /// rare case where the server returns a paginated response with a
  /// next-page cursor that never empties (e.g. a clock-skew bug).
  /// At 1000 rows/page × 25 pages we cover 25k entries; any run
  /// longer than that is, by construction, broken.
  final int maxPages;

  NetworkSessionReplayDataSource({
    required this.backend,
    this.pageSize = 1000,
    this.maxPages = 25,
  }) {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    if (maxPages <= 0) {
      throw ArgumentError.value(maxPages, 'maxPages', 'must be positive');
    }
  }

  @override
  Future<RemoteSequenceRunDetail> fetchRun(int runId) {
    _validateRunId(runId);
    return backend.fetchSequenceRunById(runId);
  }

  @override
  Future<RemoteReplayEventsPage> fetchEvents(int runId) async {
    _validateRunId(runId);
    // Walk all pages so the timeline is complete. We re-aggregate
    // the `is_partial` flag — if ANY page reports partial we
    // propagate it; the first page's `source` wins because the
    // server reports a single value per ring-buffer.
    final allItems = <RemoteReplayEvent>[];
    var offset = 0;
    int? advertisedTotal;
    var partial = false;
    String? partialReason;
    var source = 'unknown';
    var complete = false;

    for (var page = 0; page < maxPages; page++) {
      final fetched = await backend.fetchSequenceRunEvents(
        runId,
        limit: pageSize,
        offset: offset,
      );
      if (page == 0) {
        source = fetched.source;
        advertisedTotal = fetched.total;
      } else if (fetched.total != advertisedTotal) {
        throw StateError(
          'Replay event total changed during pagination '
          '($advertisedTotal → ${fetched.total})',
        );
      }
      if (fetched.items.length > pageSize) {
        throw StateError(
          'Replay event page returned ${fetched.items.length} rows for a '
          '$pageSize-row request',
        );
      }
      if (fetched.isPartial) {
        partial = true;
        partialReason ??= fetched.partialReason;
      }
      if (allItems.isNotEmpty &&
          fetched.items.isNotEmpty &&
          fetched.items.first.timestampMs < allItems.last.timestampMs) {
        throw StateError('Replay event pages are not chronological');
      }
      allItems.addAll(fetched.items);
      offset += fetched.items.length;
      if (offset > fetched.total) {
        throw StateError(
          'Replay event pages exceeded advertised total ${fetched.total}',
        );
      }
      if (fetched.items.isEmpty && offset < fetched.total) {
        partial = true;
        partialReason ??= 'server_empty_page';
        break;
      }
      if (offset >= fetched.total) {
        complete = true;
        break;
      }
    }
    final total = advertisedTotal ?? 0;
    if (!complete && offset < total) {
      partial = true;
      partialReason ??= 'client_page_limit';
    }

    return RemoteReplayEventsPage(
      items: allItems,
      total: total,
      isPartial: partial,
      source: source,
      partialReason: partialReason,
    );
  }

  @override
  Future<List<RemoteReplayFrame>> fetchFrames(int runId) async {
    _validateRunId(runId);
    final allItems = <RemoteReplayFrame>[];
    final knownIds = <int>{};
    var offset = 0;
    int? advertisedTotal;
    var complete = false;
    for (var page = 0; page < maxPages; page++) {
      final fetched = await backend.fetchSequenceRunFrames(
        runId,
        limit: pageSize,
        offset: offset,
      );
      if (page == 0) {
        advertisedTotal = fetched.total;
      } else if (fetched.total != advertisedTotal) {
        throw StateError(
          'Replay frame total changed during pagination '
          '($advertisedTotal → ${fetched.total})',
        );
      }
      if (fetched.items.length > pageSize) {
        throw StateError(
          'Replay frame page returned ${fetched.items.length} rows for a '
          '$pageSize-row request',
        );
      }
      for (final frame in fetched.items) {
        if (!knownIds.add(frame.id)) {
          throw StateError(
            'Replay frame pagination returned duplicate frame id ${frame.id}',
          );
        }
        allItems.add(frame);
      }
      offset += fetched.items.length;
      if (offset > fetched.total) {
        throw StateError(
          'Replay frame pages exceeded advertised total ${fetched.total}',
        );
      }
      if (fetched.items.isEmpty && offset < fetched.total) {
        throw StateError(
          'Replay frame pagination returned an empty page at $offset of '
          '${fetched.total} rows',
        );
      }
      if (offset >= fetched.total) {
        complete = true;
        break;
      }
    }
    final total = advertisedTotal ?? 0;
    if (!complete && offset < total) {
      throw StateError(
        'Replay frame history exceeds the safe pagination limit '
        '($offset of $total rows loaded)',
      );
    }
    return allItems;
  }

  void _validateRunId(int runId) {
    if (runId <= 0) {
      throw ArgumentError.value(runId, 'runId', 'must be positive');
    }
  }
}

/// Riverpod notifier driving the replay screen. Holds the loaded
/// markers, the playhead, and a derived snapshot stream the UI
/// binds to.
///
/// Lifecycle:
///   * Construction → [SessionReplayLoading]
///   * Fetches resolve → [SessionReplayReady] with playhead=0
///   * Any fetch throws → [SessionReplayError]
///
/// The provider [sessionReplayNotifierProvider] is family-scoped on
/// runId so the screen can `ref.watch(...(runId))` without pulling
/// any other run's state into scope.
class SessionReplayNotifier extends StateNotifier<SessionReplayState> {
  final SessionReplayDataSource dataSource;
  final int runId;

  /// Broadcasts a new [ReplaySnapshot] every time the playhead
  /// moves OR the timeline is reloaded. Subscribers listen with
  /// `StreamBuilder<ReplaySnapshot>`.
  final StreamController<ReplaySnapshot> _snapshotController =
      StreamController<ReplaySnapshot>.broadcast();

  /// Periodic ticker that advances the playhead during playback.
  /// 30 Hz cadence — visually smooth on a phone, cheap enough that
  /// we don't see GC churn even on long sessions.
  static const Duration _tickInterval = Duration(milliseconds: 33);
  Timer? _playbackTimer;

  /// Wall-clock anchor for the playback ticker. Each tick advances
  /// the playhead by `(now - _playbackAnchor) * playbackSpeed`.
  /// Reset on every `play()` and on every `seekTo` during playback.
  DateTime? _playbackAnchor;
  int? _playbackAnchorPlayheadMs;
  int _loadGeneration = 0;

  SessionReplayNotifier({required this.runId, required this.dataSource})
    : super(SessionReplayLoading(runId)) {
    _bootstrap();
  }

  Stream<ReplaySnapshot> get snapshotStream => _snapshotController.stream;

  /// Latest snapshot synchronously available. Useful for initial
  /// frame after the StreamBuilder mounts but before the first
  /// stream event lands.
  ReplaySnapshot? get latestSnapshot => _latestSnapshot;
  ReplaySnapshot? _latestSnapshot;

  Future<void> _bootstrap() async {
    final loadGeneration = ++_loadGeneration;
    try {
      // Concurrent fetches: the three endpoints are independent. The
      // run header is required to anchor the timeline; events and
      // frames can fail-partial individually, but we surface a fetch
      // throw because it's not the same as "no data".
      final results = await Future.wait([
        dataSource.fetchRun(runId),
        dataSource.fetchEvents(runId),
        dataSource.fetchFrames(runId),
      ]);
      final run = results[0] as RemoteSequenceRunDetail;
      final eventsPage = results[1] as RemoteReplayEventsPage;
      final frames = results[2] as List<RemoteReplayFrame>;
      if (!mounted || loadGeneration != _loadGeneration) return;
      if (run.id != runId) {
        throw StateError(
          'Replay data source returned run ${run.id} for requested run $runId',
        );
      }
      if (!eventsPage.isPartial &&
          eventsPage.total != eventsPage.items.length) {
        throw StateError(
          'Replay event history claimed ${eventsPage.total} rows but loaded '
          '${eventsPage.items.length}',
        );
      }

      final runStartedMs = run.startedAt.millisecondsSinceEpoch;
      final markers = <ReplayMarker>[
        for (final e in eventsPage.items)
          ReplayEventMarker.fromRemote(e, runStartedMs),
        for (final f in frames) ReplayFrameMarker.fromRemote(f, runStartedMs),
      ]..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
      if (markers.isNotEmpty && markers.first.offsetMs < 0) {
        throw StateError(
          'Replay timeline contains data before the run started',
        );
      }

      // Duration: prefer the explicit endedAt; fall back to the last
      // marker's offset (so a still-running session has a usable
      // timeline even before the end-of-run header lands); ultimately
      // floor to 1s so the scrubber never has a zero-width track.
      final endedMs = run.endedAt?.millisecondsSinceEpoch;
      final lastMarkerOffset = markers.isNotEmpty ? markers.last.offsetMs : 0;
      final recordedDurationMs = endedMs == null ? 0 : endedMs - runStartedMs;
      final runningDurationMs = endedMs == null
          ? DateTime.now().millisecondsSinceEpoch - runStartedMs
          : 0;
      final computedDurationMs = [
        recordedDurationMs,
        runningDurationMs,
        lastMarkerOffset,
      ].reduce((a, b) => a > b ? a : b);
      final durationMs = computedDurationMs > 0 ? computedDurationMs : 1000;

      state = SessionReplayReady(
        runId: runId,
        run: run,
        markers: markers,
        durationMs: durationMs,
        playheadMs: 0,
        isPlaying: false,
        playbackSpeed: 1.0,
        eventsPartial: eventsPage.isPartial,
        eventsPartialReason: eventsPage.partialReason,
      );
      _emitSnapshot();
    } catch (e) {
      if (!mounted || loadGeneration != _loadGeneration) return;
      // Surface the cause and a human message: the UI renders this as a
      // distinct screen state with a "Retry" button, where a swallowed failure
      // would render an empty timeline that looks like a quiet run. Do NOT
      // re-throw or escalate to Zone.handleUncaughtError — the
      // SessionReplayError state IS the load-failure surface, and escalating
      // crashes the test harness on a failure already captured.
      state = SessionReplayError(
        runId: runId,
        message: 'Failed to load replay: $e',
        cause: e,
      );
    }
  }

  /// Re-run the bootstrap fetches. Resets the playhead to 0 and
  /// re-loads the run header + events + frames; useful from the
  /// error-state retry button.
  Future<void> reload() async {
    if (mounted) {
      state = SessionReplayLoading(runId);
      await _bootstrap();
    }
  }

  /// Move the playhead to [offsetMs]. Clamped to the run's duration.
  /// Resets the playback anchor so a `play()` after `seekTo()` does
  /// not jump backwards by the elapsed timer interval.
  void seekTo(int offsetMs) {
    final current = state;
    if (current is! SessionReplayReady) return;
    final clamped = offsetMs.clamp(0, current.durationMs);
    state = current.copyWith(playheadMs: clamped);
    if (current.isPlaying) {
      _resetPlaybackAnchor(clamped);
    }
    _emitSnapshot();
  }

  /// Seek to the offset of a specific marker. Used when the user
  /// taps a tick on the timeline.
  void seekToMarker(ReplayMarker marker) {
    seekTo(marker.offsetMs);
  }

  /// Start playback. Plays at [SessionReplayReady.playbackSpeed]
  /// (default 1.0); change via [setPlaybackSpeed]. Playback stops
  /// automatically when the playhead reaches the end of the run.
  void play() {
    final current = state;
    if (current is! SessionReplayReady) return;
    if (current.isPlaying) return;
    state = current.copyWith(isPlaying: true);
    _resetPlaybackAnchor(current.playheadMs);
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(_tickInterval, (_) => _onTick());
  }

  /// Pause playback. Does NOT reset the playhead; resume with [play].
  void pause() {
    final current = state;
    if (current is! SessionReplayReady) return;
    if (!current.isPlaying) return;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _playbackAnchor = null;
    _playbackAnchorPlayheadMs = null;
    state = current.copyWith(isPlaying: false);
  }

  /// Toggle play/pause. Wired to the scrubber's transport button.
  void togglePlayback() {
    final current = state;
    if (current is! SessionReplayReady) return;
    if (current.isPlaying) {
      pause();
    } else {
      play();
    }
  }

  /// Update the playback rate. 1.0 = real-time. The provider
  /// accepts any positive value but the UI exposes 1×/4×/16× and a
  /// "fast" (60×) preset.
  void setPlaybackSpeed(double speed) {
    if (speed <= 0) return;
    final current = state;
    if (current is! SessionReplayReady) return;
    state = current.copyWith(playbackSpeed: speed);
    if (current.isPlaying) {
      _resetPlaybackAnchor(current.playheadMs);
    }
  }

  void _resetPlaybackAnchor(int playheadMs) {
    _playbackAnchor = DateTime.now();
    _playbackAnchorPlayheadMs = playheadMs;
  }

  void _onTick() {
    final current = state;
    if (current is! SessionReplayReady || !current.isPlaying) return;
    final anchor = _playbackAnchor;
    final anchorPlayhead = _playbackAnchorPlayheadMs;
    if (anchor == null || anchorPlayhead == null) return;
    final elapsedMs = DateTime.now().difference(anchor).inMilliseconds;
    final advance = (elapsedMs * current.playbackSpeed).round();
    final nextPlayhead = anchorPlayhead + advance;
    if (nextPlayhead >= current.durationMs) {
      // Reached end — clamp + auto-pause so the operator doesn't have
      // to chase the slider back from its rightmost position.
      state = current.copyWith(
        playheadMs: current.durationMs,
        isPlaying: false,
      );
      _playbackTimer?.cancel();
      _playbackTimer = null;
      _playbackAnchor = null;
      _playbackAnchorPlayheadMs = null;
      _emitSnapshot();
      return;
    }
    state = current.copyWith(playheadMs: nextPlayhead);
    _emitSnapshot();
  }

  /// Scan the timeline up to the current playhead, materialising the
  /// snapshot. Pure function of `(state.markers, state.playheadMs)`.
  ///
  /// Exposed (visible-for-testing) so the snapshot logic can be
  /// exercised independently of the StateNotifier wiring.
  ReplaySnapshot computeSnapshotAt(int playheadMs) {
    final current = state;
    if (current is! SessionReplayReady) {
      // Empty snapshot is safe — the UI is gated on Ready anyway.
      return ReplaySnapshot(
        playheadMs: playheadMs,
        playheadWallClock: DateTime.now(),
        frameCount: 0,
        markersUpToPlayhead: const [],
        allMarkers: const [],
      );
    }

    final upTo = <ReplayMarker>[];
    String? currentTarget = current.run.targetName;
    String? currentNodeName;
    String? currentFilter;
    double? lastHfr;
    double? lastGuideRmsTotal;
    String? recoveryState;
    var frameCount = 0;

    for (final m in current.markers) {
      if (m.offsetMs > playheadMs) break;
      upTo.add(m);
      switch (m) {
        case ReplayFrameMarker frame:
          frameCount++;
          if (frame.filter != null) currentFilter = frame.filter;
          if (frame.hfr != null) lastHfr = frame.hfr;
          if (frame.guideRmsTotal != null) {
            lastGuideRmsTotal = frame.guideRmsTotal;
          }
        case ReplayEventMarker event:
          final fields = event.fields;
          if (fields != null) {
            final t = fields['target'] ?? fields['targetName'];
            if (t is String && t.isNotEmpty) currentTarget = t;
            final n = fields['nodeName'] ?? fields['currentNodeName'];
            if (n is String && n.isNotEmpty) currentNodeName = n;
            final f = fields['filter'];
            if (f is String && f.isNotEmpty) currentFilter = f;
          }
          // Recovery state events: the event-bus convention is
          // type `recovery.entered` / `recovery.completed` (see
          // RecoveryHistoryEntry in recovery_provider.dart). The
          // log entry's `source` carries the category breadcrumb
          // we need; we encode the state purely from the message
          // body since `fields.state` isn't guaranteed.
          final lcMessage = event.message.toLowerCase();
          if (lcMessage.contains('recovery.entered') ||
              lcMessage.contains('recovery entered')) {
            recoveryState = 'entered';
          } else if (lcMessage.contains('recovery.completed') ||
              lcMessage.contains('recovery completed')) {
            recoveryState = 'completed';
          }
      }
    }

    final wallClock = current.run.startedAt.add(
      Duration(milliseconds: playheadMs),
    );
    return ReplaySnapshot(
      playheadMs: playheadMs,
      playheadWallClock: wallClock,
      frameCount: frameCount,
      markersUpToPlayhead: upTo,
      allMarkers: current.markers,
      currentTarget: currentTarget,
      currentNodeName: currentNodeName,
      currentFilter: currentFilter,
      lastHfr: lastHfr,
      lastGuideRmsTotal: lastGuideRmsTotal,
      recoveryState: recoveryState,
    );
  }

  void _emitSnapshot() {
    final current = state;
    if (current is! SessionReplayReady) return;
    final snapshot = computeSnapshotAt(current.playheadMs);
    _latestSnapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _snapshotController.close();
    super.dispose();
  }
}

/// Provider-level construction parameters. We use a record-shaped key
/// so the family auto-disposes the notifier when the screen goes away
/// (Riverpod compares records by `==`, not identity).
typedef SessionReplayKey = ({int runId, SessionReplayDataSource dataSource});

/// Family provider exposing the [SessionReplayNotifier] for a given
/// runId + data source pair. Callers in the mobile screen layer
/// build the data source from the active NetworkBackend and pass it
/// in; tests pass a stub data source.
final sessionReplayNotifierProvider = StateNotifierProvider.autoDispose
    .family<SessionReplayNotifier, SessionReplayState, SessionReplayKey>(
      (ref, key) =>
          SessionReplayNotifier(runId: key.runId, dataSource: key.dataSource),
    );
