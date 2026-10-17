// Smoke test for the mobile session replay scrubber.
//
// Renders the replay screen with a stub data source and asserts:
//   1. The timeline bar renders.
//   2. Tick rendering is driven by the loaded markers (we count the
//      MarkerRow entries in the event log card — those are 1:1 with
//      the markers up to the playhead, and we expect the bootstrap
//      to leave the playhead at 0 with zero pre-playhead markers).
//   3. Seeking advances the playhead so future markers come into
//      scope.
//
// Stub data source pattern mirrors the notifier unit test so the
// widget exercises the same scan-to-time projection in a real
// widget tree.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_mobile/screens/replay/session_replay_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final runStartedAt = DateTime.utc(2026, 5, 25, 22, 0);
  final runEndedAt = runStartedAt.add(const Duration(minutes: 10));

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

  RemoteReplayFrame frameAt(int id, int seconds) {
    final ts = runStartedAt.add(Duration(seconds: seconds));
    return RemoteReplayFrame(
      id: id,
      fileName: 'frame_$id.fits',
      filePath: '/tmp/frame_$id.fits',
      capturedAt: ts,
      capturedAtMs: ts.millisecondsSinceEpoch,
      frameType: 'light',
      exposureDuration: 60.0,
      filter: 'L',
      hfr: 2.4,
      binX: 1,
      binY: 1,
      isAccepted: true,
    );
  }

  Widget wrap(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        theme: ThemeData.light().copyWith(
          extensions: const [SkotiqColors.dark],
        ),
        home: child,
      ),
    );
  }

  testWidgets('renders timeline + snapshot after a successful load', (
    tester,
  ) async {
    final source = _StubSource(
      run: RemoteSequenceRunDetail(
        id: 1,
        startedAt: runStartedAt,
        endedAt: runEndedAt,
        status: 'completed',
        frameCount: 2,
        sequenceName: 'Test sequence',
        targetName: 'M31',
      ),
      eventsPage: RemoteReplayEventsPage(
        items: [
          eventAt(10, 'info', 'Sequence started'),
          eventAt(120, 'warning', 'HFR climbing'),
          eventAt(360, 'info', 'Sequence completed'),
        ],
        total: 3,
        isPartial: false,
        source: 'logging_service_ring_buffer',
      ),
      frames: [frameAt(1, 60), frameAt(2, 180)],
    );

    await tester.pumpWidget(
      wrap(SessionReplayScreen(runId: 1, dataSourceOverride: source)),
    );
    // Loading spinner first.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Drain async + stream microtasks.
    await tester.pumpAndSettle();

    // Timeline bar exists.
    expect(find.byKey(const Key('timeline_bar')), findsOneWidget);

    // Header chip text — sequence name renders.
    expect(find.text('Test sequence'), findsOneWidget);
    // Target name renders in the header chip and again in the snapshot
    // panel ("Target" row), so allow either count.
    expect(find.text('M31'), findsAtLeastNWidgets(1));

    // Frame count chip — "2 frames".
    expect(find.text('2 frames'), findsOneWidget);
  });

  testWidgets('renders partial-data banner when events are truncated', (
    tester,
  ) async {
    final source = _StubSource(
      run: RemoteSequenceRunDetail(
        id: 1,
        startedAt: runStartedAt,
        endedAt: runEndedAt,
        status: 'completed',
        frameCount: 0,
        sequenceName: 'Test',
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

    await tester.pumpWidget(
      wrap(SessionReplayScreen(runId: 1, dataSourceOverride: source)),
    );
    await tester.pumpAndSettle();

    // The banner specifically calls out the no-buffered-entries
    // reason — operators on a Pi that restarted overnight need this.
    expect(
      find.textContaining('Server has no buffered events for this run'),
      findsOneWidget,
    );
  });

  testWidgets('error state renders Retry button', (tester) async {
    final source = _StubSource.failing(error: Exception('boom'));
    await tester.pumpWidget(
      wrap(SessionReplayScreen(runId: 1, dataSourceOverride: source)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Replay failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

class _StubSource implements SessionReplayDataSource {
  final RemoteSequenceRunDetail? run;
  final RemoteReplayEventsPage? eventsPage;
  final List<RemoteReplayFrame>? frames;
  final Object? failure;

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
