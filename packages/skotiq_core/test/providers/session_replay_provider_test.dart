// Tests for the session replay notifier's snapshot
// computation (scan-to-time correctness) and lifecycle.
//
// The notifier's bootstrap is wired through a stub
// `SessionReplayDataSource` so the tests exercise the real scan logic
// without any HTTP plumbing.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed run window: started at t=0, ended 10 minutes later.
  final runStartedAt = DateTime.utc(2026, 5, 25, 22, 0);
  final runEndedAt = runStartedAt.add(const Duration(minutes: 10));
  const int runId = 42;

  RemoteReplayEvent eventAt(int seconds, String severity, String message) {
    final ts = runStartedAt.add(Duration(seconds: seconds));
    return RemoteReplayEvent(
      timestamp: ts,
      timestampMs: ts.millisecondsSinceEpoch,
      severity: severity,
      source: 'TestSource',
      message: message,
    );
  }

  RemoteReplayFrame frameAt(
    int id,
    int seconds, {
    String? filter,
    double? hfr,
  }) {
    final ts = runStartedAt.add(Duration(seconds: seconds));
    return RemoteReplayFrame(
      id: id,
      fileName: 'frame_$id.fits',
      filePath: '/tmp/frame_$id.fits',
      capturedAt: ts,
      capturedAtMs: ts.millisecondsSinceEpoch,
      frameType: 'light',
      exposureDuration: 60.0,
      filter: filter,
      hfr: hfr,
      binX: 1,
      binY: 1,
      isAccepted: true,
    );
  }

  group('SessionReplayNotifier', () {
    test('bootstrap transitions Loading → Ready and merges markers', () async {
      final source = _StubSource(
        run: RemoteSequenceRunDetail(
          id: runId,
          startedAt: runStartedAt,
          endedAt: runEndedAt,
          status: 'completed',
          frameCount: 3,
          sequenceName: 'Test sequence',
          targetName: 'M31',
        ),
        eventsPage: RemoteReplayEventsPage(
          items: [
            eventAt(0, 'info', 'Sequence started'),
            eventAt(120, 'info', 'Slewed to target'),
            eventAt(300, 'warning', 'HFR climbing'),
          ],
          total: 3,
          isPartial: false,
          source: 'logging_service_ring_buffer',
        ),
        frames: [
          frameAt(1, 60, filter: 'L', hfr: 2.4),
          frameAt(2, 180, filter: 'L', hfr: 2.5),
          frameAt(3, 360, filter: 'R', hfr: 2.6),
        ],
      );
      final notifier = SessionReplayNotifier(runId: runId, dataSource: source);
      // Bootstrap is async; wait for the state to land.
      await source.completed;

      expect(notifier.state, isA<SessionReplayReady>());
      final ready = notifier.state as SessionReplayReady;
      expect(ready.markers, hasLength(6));
      // Markers are sorted ascending by offset.
      for (var i = 1; i < ready.markers.length; i++) {
        expect(
          ready.markers[i].offsetMs,
          greaterThanOrEqualTo(ready.markers[i - 1].offsetMs),
        );
      }
      expect(ready.durationMs, const Duration(minutes: 10).inMilliseconds);
      expect(ready.playheadMs, 0);
      expect(ready.eventsPartial, isFalse);
      notifier.dispose();
    });

    test(
      'computeSnapshotAt(t) projects only markers with offset <= t',
      () async {
        final source = _StubSource(
          run: RemoteSequenceRunDetail(
            id: runId,
            startedAt: runStartedAt,
            endedAt: runEndedAt,
            status: 'completed',
            frameCount: 3,
            sequenceName: 'Test sequence',
            targetName: 'M31',
          ),
          eventsPage: RemoteReplayEventsPage(
            items: [
              eventAt(0, 'info', 'Sequence started'),
              eventAt(60, 'info', 'Slewed to target'),
              eventAt(180, 'warning', 'HFR climbing'),
              eventAt(360, 'info', 'recovery.entered: autofocus drift'),
            ],
            total: 4,
            isPartial: false,
            source: 'logging_service_ring_buffer',
          ),
          frames: [
            frameAt(1, 30, filter: 'L', hfr: 2.4),
            frameAt(2, 90, filter: 'L', hfr: 2.5),
            frameAt(3, 240, filter: 'R', hfr: 2.6),
          ],
        );
        final notifier = SessionReplayNotifier(
          runId: runId,
          dataSource: source,
        );
        await source.completed;

        // Playhead at t=120s.
        const playheadMs = 120 * 1000;
        final snap = notifier.computeSnapshotAt(playheadMs);

        // Markers BEFORE 120s: events at 0, 60; frames at 30, 90 → 4.
        // Markers AFTER 120s (180, 240, 360) must be excluded.
        expect(snap.markersUpToPlayhead, hasLength(4));
        for (final m in snap.markersUpToPlayhead) {
          expect(m.offsetMs, lessThanOrEqualTo(playheadMs));
        }
        // Frame count reflects the two frames at t<=120 only.
        expect(snap.frameCount, 2);
        // Most-recent filter at the playhead is L (frame at t=90s).
        expect(snap.currentFilter, 'L');
        // HFR follows the latest frame at or before the playhead → 2.5.
        expect(snap.lastHfr, 2.5);
        // Target falls back to the run header value because no event
        // payload sets a fresh target before t=120s.
        expect(snap.currentTarget, 'M31');
        // Recovery state has not been touched at this playhead.
        expect(snap.recoveryState, isNull);
        // Wall-clock at playhead = runStartedAt + 120s.
        expect(snap.playheadWallClock.difference(runStartedAt).inSeconds, 120);

        // Advance the playhead past the recovery event and verify the
        // recoveryState lights up.
        final lateSnap = notifier.computeSnapshotAt(400 * 1000);
        expect(lateSnap.recoveryState, 'entered');
        expect(lateSnap.frameCount, 3);

        notifier.dispose();
      },
    );

    test('seekTo clamps playhead to [0, durationMs]', () async {
      final source = _StubSource(
        run: RemoteSequenceRunDetail(
          id: runId,
          startedAt: runStartedAt,
          endedAt: runEndedAt,
          status: 'completed',
          frameCount: 0,
          sequenceName: 'Empty run',
        ),
        eventsPage: const RemoteReplayEventsPage(
          items: [],
          total: 0,
          isPartial: true,
          source: 'logging_service_ring_buffer',
          partialReason: 'no_buffered_entries',
        ),
        frames: const [],
      );
      final notifier = SessionReplayNotifier(runId: runId, dataSource: source);
      await source.completed;

      notifier.seekTo(-1000);
      expect((notifier.state as SessionReplayReady).playheadMs, 0);

      notifier.seekTo(99999999);
      final ready = notifier.state as SessionReplayReady;
      expect(ready.playheadMs, ready.durationMs);
      // is_partial flag propagates through to the Ready state.
      expect(ready.eventsPartial, isTrue);
      expect(ready.eventsPartialReason, 'no_buffered_entries');

      notifier.dispose();
    });

    test('duration includes markers recorded just after endedAt', () async {
      final source = _StubSource(
        run: RemoteSequenceRunDetail(
          id: runId,
          startedAt: runStartedAt,
          endedAt: runEndedAt,
          status: 'completed',
          frameCount: 1,
        ),
        eventsPage: const RemoteReplayEventsPage(
          items: [],
          total: 0,
          isPartial: false,
          source: 'logging_service_ring_buffer',
        ),
        frames: [frameAt(1, 660)],
      );
      final notifier = SessionReplayNotifier(runId: runId, dataSource: source);
      await source.completed;

      final ready = notifier.state as SessionReplayReady;
      expect(ready.durationMs, const Duration(minutes: 11).inMilliseconds);
      notifier.seekTo(ready.durationMs);
      expect(notifier.computeSnapshotAt(ready.durationMs).frameCount, 1);
      notifier.dispose();
    });

    test('disposing during bootstrap ignores the late response', () async {
      final source = _DeferredSource();
      final notifier = SessionReplayNotifier(runId: runId, dataSource: source);
      notifier.dispose();

      source.complete(
        run: RemoteSequenceRunDetail(
          id: runId,
          startedAt: runStartedAt,
          endedAt: runEndedAt,
          status: 'completed',
          frameCount: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });

    test('a data-source failure transitions to SessionReplayError', () async {
      final source = _StubSource.failing(
        error: Exception('connection refused'),
      );
      final notifier = SessionReplayNotifier(runId: runId, dataSource: source);
      // Drain pending microtasks so the bootstrap can run + the
      // notifier can settle into the error state.
      await Future<void>.delayed(Duration.zero);
      // Drain again — the Zone.handleUncaughtError call defers.
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state, isA<SessionReplayError>());
      final err = notifier.state as SessionReplayError;
      expect(err.runId, runId);
      expect(err.message, contains('Failed to load replay'));
      notifier.dispose();
    });

    test('snapshotStream emits a new snapshot after each seekTo', () async {
      final source = _StubSource(
        run: RemoteSequenceRunDetail(
          id: runId,
          startedAt: runStartedAt,
          endedAt: runEndedAt,
          status: 'completed',
          frameCount: 0,
          sequenceName: 'Empty run',
        ),
        eventsPage: const RemoteReplayEventsPage(
          items: [],
          total: 0,
          isPartial: false,
          source: 'logging_service_ring_buffer',
        ),
        frames: const [],
      );
      final notifier = SessionReplayNotifier(runId: runId, dataSource: source);
      await source.completed;

      final emitted = <int>[];
      final sub = notifier.snapshotStream.listen((s) {
        emitted.add(s.playheadMs);
      });
      notifier.seekTo(1000);
      notifier.seekTo(2500);
      // Let the broadcast controller dispatch its microtasks.
      await Future<void>.delayed(Duration.zero);
      expect(emitted, containsAllInOrder(<int>[1000, 2500]));
      await sub.cancel();
      notifier.dispose();
    });
  });

  group('NetworkSessionReplayDataSource pagination', () {
    test(
      'marks event history partial when the client page cap is hit',
      () async {
        final backend = _PagingBackend();
        backend.eventPages[0] = RemoteReplayEventsPage(
          items: [eventAt(1, 'info', 'first')],
          total: 2,
          isPartial: false,
          source: 'logging_service_ring_buffer',
        );
        final source = NetworkSessionReplayDataSource(
          backend: backend,
          pageSize: 1,
          maxPages: 1,
        );

        final page = await source.fetchEvents(runId);

        expect(page.isPartial, isTrue);
        expect(page.partialReason, 'client_page_limit');
      },
    );

    test(
      'fails instead of silently truncating frames at the page cap',
      () async {
        final backend = _PagingBackend();
        backend.framePages[0] = RemotePage(items: [frameAt(1, 1)], total: 2);
        final source = NetworkSessionReplayDataSource(
          backend: backend,
          pageSize: 1,
          maxPages: 1,
        );

        await expectLater(source.fetchFrames(runId), throwsStateError);
      },
    );

    test('marks an early empty event page as partial', () async {
      final backend = _PagingBackend();
      backend.eventPages[0] = const RemoteReplayEventsPage(
        items: [],
        total: 2,
        isPartial: false,
        source: 'logging_service_ring_buffer',
      );
      final source = NetworkSessionReplayDataSource(
        backend: backend,
        pageSize: 1,
      );

      final page = await source.fetchEvents(runId);

      expect(page.items, isEmpty);
      expect(page.total, 2);
      expect(page.isPartial, isTrue);
      expect(page.partialReason, 'server_empty_page');
    });

    test('fails on early empty or duplicate frame pages', () async {
      final emptyBackend = _PagingBackend();
      emptyBackend.framePages[0] = const RemotePage(items: [], total: 2);
      final emptySource = NetworkSessionReplayDataSource(
        backend: emptyBackend,
        pageSize: 1,
      );
      await expectLater(emptySource.fetchFrames(runId), throwsStateError);

      final duplicateBackend = _PagingBackend();
      duplicateBackend.framePages[0] = RemotePage(
        items: [frameAt(1, 1)],
        total: 2,
      );
      duplicateBackend.framePages[1] = RemotePage(
        items: [frameAt(1, 2)],
        total: 2,
      );
      final duplicateSource = NetworkSessionReplayDataSource(
        backend: duplicateBackend,
        pageSize: 1,
      );
      await expectLater(duplicateSource.fetchFrames(runId), throwsStateError);
    });

    test('rejects non-positive pagination configuration and run ids', () async {
      final backend = _PagingBackend();
      expect(
        () => NetworkSessionReplayDataSource(backend: backend, pageSize: 0),
        throwsArgumentError,
      );
      expect(
        () => NetworkSessionReplayDataSource(backend: backend, maxPages: 0),
        throwsArgumentError,
      );
      final source = NetworkSessionReplayDataSource(backend: backend);
      await expectLater(source.fetchEvents(0), throwsArgumentError);
      await expectLater(source.fetchFrames(-1), throwsArgumentError);
    });
  });
}

/// Stub data source that hands back canned results to exercise the
/// notifier's state machine without HTTP plumbing.
class _StubSource implements SessionReplayDataSource {
  final RemoteSequenceRunDetail? run;
  final RemoteReplayEventsPage? eventsPage;
  final List<RemoteReplayFrame>? frames;
  final Object? failure;

  // We don't need futures-with-completers here; the tests just await
  // a fresh delay before asserting. But exposing a `completed` getter
  // makes the test prose read more naturally.
  Future<void> get completed async {
    // Yield twice: once for the Future.wait chain, once for the
    // notifier's state assignment microtask.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  _StubSource({
    required this.run,
    required this.eventsPage,
    required this.frames,
  }) : failure = null;

  _StubSource.failing({required Object error})
    : run = null,
      eventsPage = null,
      frames = null,
      failure = error;

  @override
  Future<RemoteSequenceRunDetail> fetchRun(int runId) async {
    if (failure != null) throw failure!;
    return run!;
  }

  @override
  Future<RemoteReplayEventsPage> fetchEvents(int runId) async {
    if (failure != null) throw failure!;
    return eventsPage!;
  }

  @override
  Future<List<RemoteReplayFrame>> fetchFrames(int runId) async {
    if (failure != null) throw failure!;
    return frames!;
  }
}

class _DeferredSource implements SessionReplayDataSource {
  final _run = Completer<RemoteSequenceRunDetail>();
  final _events = Completer<RemoteReplayEventsPage>();
  final _frames = Completer<List<RemoteReplayFrame>>();

  void complete({required RemoteSequenceRunDetail run}) {
    _run.complete(run);
    _events.complete(
      const RemoteReplayEventsPage(
        items: [],
        total: 0,
        isPartial: false,
        source: 'test',
      ),
    );
    _frames.complete(const []);
  }

  @override
  Future<RemoteSequenceRunDetail> fetchRun(int runId) => _run.future;

  @override
  Future<RemoteReplayEventsPage> fetchEvents(int runId) => _events.future;

  @override
  Future<List<RemoteReplayFrame>> fetchFrames(int runId) => _frames.future;
}

class _PagingBackend extends NetworkBackend {
  final Map<int, RemoteReplayEventsPage> eventPages = {};
  final Map<int, RemotePage<RemoteReplayFrame>> framePages = {};

  _PagingBackend()
    : super(serverHost: '127.0.0.1', autoConnectWebSocket: false);

  @override
  Future<RemoteReplayEventsPage> fetchSequenceRunEvents(
    int runId, {
    int? sinceMs,
    int? untilMs,
    String? severityMin,
    int limit = 200,
    int offset = 0,
  }) async =>
      eventPages[offset] ??
      const RemoteReplayEventsPage(
        items: [],
        total: 0,
        isPartial: false,
        source: 'test',
      );

  @override
  Future<RemotePage<RemoteReplayFrame>> fetchSequenceRunFrames(
    int runId, {
    int limit = 200,
    int offset = 0,
  }) async => framePages[offset] ?? const RemotePage(items: [], total: 0);
}
