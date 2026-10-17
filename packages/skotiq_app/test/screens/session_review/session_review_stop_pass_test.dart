// The operator's way out of a Darkroom pass that is already running.
//
// "Process now" starts minutes of native rendering per master. Without a Stop
// control, a pass started over the wrong night — or started at all when the
// machine is wanted for something else — can only be waited out or killed with
// the app. The engine has a cancellation path (`DawnAutopilotService
// .requestCancel`); until this control nothing on the screen reached it.
//
// The stop is cooperative, so these tests pin the honest shape of it: the
// control appears only while a pass is live, one press reaches the RUNNING
// job's id, and the control then states that it is stopping rather than
// claiming the pass is over.
//
// They also pin what the header reads the answer FROM. It used to be a
// per-screen latch, so a Session Review that had been popped and re-pushed over
// a session already being processed came back with the latch clear and offered
// "Process now" again — two passes then ran over one night and Stop reached one
// of them (D3LC2-F1). The durable `darkroom_jobs` row is the authority now, and
// a fresh screen state reads the same answer as the one it replaced.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/session_review_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import 'seeded_review_fixture.dart';

class _MockDawn extends Mock implements DawnAutopilotService {}

class _MockJobs extends Mock implements DarkroomJobsDao {}

/// Pins the backend so the screen's host-only gate resolves without the real
/// notifier's connection polling leaving a timer alive past teardown.
class _PinnedBackend extends BackendNotifier {
  _PinnedBackend(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

DarkroomJob _job(DarkroomJobState state, {int id = 42}) => DarkroomJob(
      id: id,
      sessionId: 1,
      kind: DarkroomJobKind.manual,
      state: state,
      progress: 0.4,
      attempts: 1,
      createdAt: DateTime.utc(2026, 8, 16),
      startedAt: DateTime.utc(2026, 8, 16),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late String previewPath;
  late _MockDawn dawn;
  late _MockJobs jobs;
  late Completer<DawnJobOutcome> pass;

  setUp(() async {
    db = mockDatabase();
    previewPath = await _writeSamplePng();
    dawn = _MockDawn();
    jobs = _MockJobs();
    pass = Completer<DawnJobOutcome>();
    when(() => dawn.processSessionNow(any())).thenAnswer((_) => pass.future);
    when(
      () => dawn.requestCancel(any(), reason: any(named: 'reason')),
    ).thenAnswer((_) async {});
    // The default world: nothing is live over this session. Each test that
    // needs a live pass says so.
    when(() => dawn.liveJobsForSession(any())).thenAnswer((_) async => []);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const scope = SessionReviewScope.session(1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _PinnedBackend(ref, DisconnectedBackend()),
          ),
          dawnAutopilotServiceProvider.overrideWithValue(dawn),
          darkroomJobsDaoProvider.overrideWithValue(jobs),
          ...seededReviewOverrides(
            db: db,
            scope: scope,
            previewPath: previewPath,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: const SessionReviewScreen(scope: scope),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  /// Release the parked pass and unmount before the end-of-test invariants.
  ///
  /// Pumped by fixed steps, never `pumpAndSettle`: the seeded narrative view
  /// paints shimmer skeletons and the toast overlay dwells, so the tree is
  /// never frame-quiescent while it is mounted. Unmounting and letting the
  /// clock run is what navigating away does.
  Future<void> finish(WidgetTester tester) async {
    if (!pass.isCompleted) {
      pass.complete(
        const DawnJobOutcome(
          jobId: 42,
          state: DarkroomJobState.cancelled,
          report: null,
          reportPath: null,
          failure: 'The Darkroom pass was stopped.',
        ),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
  }

  final stopKey = find.byKey(const ValueKey('session_review_stop_pass'));
  final processKey = find.byKey(const ValueKey('session_review_process_now'));

  /// Press a header button through its own callback.
  ///
  /// The seeded fixture's integration-shortfall toast sits in the overlay
  /// across the header for its whole dwell, so a synthetic tap lands on the
  /// toast instead. Reading the button's `onPressed` still asserts the wiring
  /// under test — that this control, enabled, reaches that action.
  Future<void> press(WidgetTester tester, Finder button) async {
    tester.widget<SkotiqButton>(button).onPressed!();
    await tester.pump();
  }

  testWidgets('no Stop control while nothing is running', (tester) async {
    await pumpScreen(tester);
    expect(
      stopKey,
      findsNothing,
      reason: 'a Stop with nothing to stop is a control that lies',
    );
    await finish(tester);
  });

  testWidgets('a running pass offers Stop, and one press reaches the job', (
    tester,
  ) async {
    when(() => dawn.liveJobsForSession(1)).thenAnswer(
      (_) async => [_job(DarkroomJobState.running)],
    );
    await pumpScreen(tester);

    // The durable row is what puts Stop on the header — this screen never
    // started the pass.
    expect(stopKey, findsOneWidget);

    await press(tester, stopKey);

    verify(
      () => dawn.requestCancel(42, reason: 'Stopped from Session Review'),
    ).called(1);

    // Cooperative, so the control says what is actually true: the request is
    // in, the pass has not ended yet.
    expect(tester.widget<SkotiqButton>(stopKey).label, 'Stopping…');
    expect(tester.widget<SkotiqButton>(stopKey).onPressed, isNull);

    await finish(tester);
  });

  testWidgets('a terminal job is never asked to stop', (tester) async {
    when(() => dawn.liveJobsForSession(1)).thenAnswer((_) async => []);
    await pumpScreen(tester);

    await press(tester, processKey);
    await press(tester, stopKey);

    verifyNever(() => dawn.requestCancel(any(), reason: any(named: 'reason')));
    // Nothing was stopped, so the control goes back to offering the stop.
    expect(tester.widget<SkotiqButton>(stopKey).label, 'Stop');
    expect(tester.widget<SkotiqButton>(stopKey).onPressed, isNotNull);

    await finish(tester);
  });

  // D3LC2-F1, the re-pushed-route shape. The screen is built fresh — every
  // per-screen latch starts clear, exactly as it did after Analytics → History
  // → Review & integrate — over a session that `darkroom_jobs` says is already
  // being processed.
  testWidgets(
      'a freshly built screen over a session already being processed '
      'offers Stop, not Process now', (tester) async {
    when(() => dawn.liveJobsForSession(1)).thenAnswer(
      (_) async => [_job(DarkroomJobState.running)],
    );

    await pumpScreen(tester);

    expect(
      tester.widget<SkotiqButton>(processKey).onPressed,
      isNull,
      reason: 'the durable row says a pass holds this night',
    );
    expect(stopKey, findsOneWidget);
    verifyNever(() => dawn.processSessionNow(any()));

    await finish(tester);
  });

  testWidgets('a queued pass disables Process now too', (tester) async {
    when(() => dawn.liveJobsForSession(1)).thenAnswer(
      (_) async => [_job(DarkroomJobState.queued)],
    );

    await pumpScreen(tester);

    expect(tester.widget<SkotiqButton>(processKey).onPressed, isNull);

    await finish(tester);
  });

  // The second half of the same defect: even if a press does get through — the
  // durable state was read a moment before the other pass began — the service
  // refuses it, and the screen says so instead of reporting a failure.
  testWidgets(
      'a press the service refuses is reported as already running, '
      'and starts nothing', (tester) async {
    await pumpScreen(tester);
    when(() => dawn.processSessionNow(1)).thenThrow(
      const DarkroomSessionBusyException(
        sessionId: 1,
        jobId: 42,
        state: DarkroomJobState.running,
      ),
    );
    when(() => dawn.liveJobsForSession(1)).thenAnswer(
      (_) async => [_job(DarkroomJobState.running)],
    );

    await press(tester, processKey);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.textContaining('already running (job 42)'),
      findsOneWidget,
      reason: 'the operator is told which pass has the night',
    );
    // The screen catches up to the durable answer rather than staying on a
    // control that would refuse again.
    expect(tester.widget<SkotiqButton>(processKey).onPressed, isNull);

    await finish(tester);
  });

  // The Stop that D3LC2-F1 caught halting only one of two passes. A build
  // without the enqueue guard can have left two live rows behind; every one of
  // them is asked to stop.
  testWidgets(
      'Stop reaches every live pass over the session, not just the '
      'newest', (tester) async {
    when(() => dawn.liveJobsForSession(1)).thenAnswer(
      (_) async => [
        _job(DarkroomJobState.running, id: 17),
        _job(DarkroomJobState.running, id: 18),
      ],
    );
    await pumpScreen(tester);

    await press(tester, stopKey);
    await tester.pump();

    verify(
      () => dawn.requestCancel(17, reason: 'Stopped from Session Review'),
    ).called(1);
    verify(
      () => dawn.requestCancel(18, reason: 'Stopped from Session Review'),
    ).called(1);

    await finish(tester);
  });
}

/// A tiny on-disk PNG for the seeded hero.
Future<String> _writeSamplePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 40, 30),
    Paint()..color = const Color(0xFF102030),
  );
  final image = await recorder.endRecording().toImage(40, 30);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = await Directory.systemTemp.createTemp('session_review_stop');
  final file = File('${dir.path}/hero.png');
  await file.writeAsBytes(Uint8List.view(bytes!.buffer));
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return file.path;
}
