// A Darkroom pass that ended badly has to be visible on the session it ran on.
//
// The dawn pass runs while nobody is at the machine, so its ending lives only
// on its `darkroom_jobs` row: the toast that reports a pass belongs to the
// button that started one, and nothing started this one. A pass that failed at
// 05:40 therefore left Session Review showing the night's verdict, the masters
// and a clean-night score with no sign that the drafting, the night report and
// the delivery for it had not happened — the operator's first clue was a
// destination that never received the night.
//
// What these pin: a failed pass and a stopped pass are stated on the session
// they belong to, with the row's own sentence — and so is a pass that ran to
// the END, because on the desktop nothing else states one. Measured on a
// completed D1 night (one `done` job, four autopilot recipes, four rendered
// drafts, nine delivered files): the Dashboard, the status bar and this screen
// mentioned none of it, and the morning notification's deep link is routed by
// the phone alone. The only way to those drafts was an unlabelled icon in an
// Analytics session dialog.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import 'seeded_review_fixture.dart';

class _MockJobs extends Mock implements DarkroomJobsDao {}

DarkroomJob _job(
  DarkroomJobState state, {
  String? errorText,
  String? note,
}) =>
    DarkroomJob(
      id: 42,
      sessionId: 1,
      kind: DarkroomJobKind.dawn,
      state: state,
      progress: 0.9,
      note: note,
      errorText: errorText,
      attempts: 1,
      createdAt: DateTime.utc(2026, 8, 16),
      startedAt: DateTime.utc(2026, 8, 16),
      finishedAt: DateTime.utc(2026, 8, 16, 5, 40),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late String previewPath;
  late _MockJobs jobs;

  setUp(() async {
    db = mockDatabase();
    previewPath = await _writeSamplePng();
    jobs = _MockJobs();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpNarrative(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const scope = SessionReviewScope.session(1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
          home: const Scaffold(body: NarrativeView(scope: scope)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  final banner =
      find.byKey(const ValueKey('session_review_darkroom_pass_banner'));
  final done = find.byKey(const ValueKey('session_review_darkroom_pass_done'));

  testWidgets('a failed dawn pass is stated on the session it ran on', (
    tester,
  ) async {
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        _job(
          DarkroomJobState.failed,
          errorText: 'The dawn job failed while delivering the night: the '
              'Darkroom output directory could not be created.',
          note: 'delivering the night',
        ),
      ],
    );

    await pumpNarrative(tester);

    expect(banner, findsOneWidget);
    final message = tester.widget<SkotiqBanner>(banner).message;
    expect(message, contains('The Darkroom pass for this night failed.'));
    expect(message, contains('could not be created'));
    expect(message, contains('delivering the night'));
    expect(message, contains('Build masters in the Darkroom'));
  });

  testWidgets('a stopped pass is stated as stopped, not as a failure', (
    tester,
  ) async {
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        _job(
          DarkroomJobState.cancelled,
          errorText: 'Stopped on request during delivery; 12 files are still '
              'owed and the retry sweep resumes them.',
        ),
      ],
    );

    await pumpNarrative(tester);

    final widget = tester.widget<SkotiqBanner>(banner);
    expect(widget.tone, BannerTone.warning);
    expect(widget.message, contains('was stopped'));
    expect(widget.message, contains('12 files are still owed'));
  });

  testWidgets(
      'a note that is already a sentence is not wrapped in the stage '
      'frame', (tester) async {
    // The open-time recovery writes a finished sentence into the same column
    // the executor writes a stage name into. Framed as a stage this rendered
    // "It was Stopped at the retry limit; this job is not re-queued. when it
    // stopped." — a full stop mid-clause and a dangling tail.
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        _job(
          DarkroomJobState.failed,
          errorText: 'Interrupted by a process exit on attempt 3; the limit '
              'is 3 starts, so it is not retried.',
          note: 'Stopped at the retry limit; this job is not re-queued.',
        ),
      ],
    );

    await pumpNarrative(tester);

    final message = tester.widget<SkotiqBanner>(banner).message;
    expect(message, isNot(contains('It was Stopped')));
    expect(message, isNot(contains('re-queued. when it stopped')));
    expect(
      message,
      contains(
        'so it is not retried. Stopped at the retry limit; this job is not '
        're-queued. The subs',
      ),
    );
  });

  testWidgets('a stage fragment still reads as one clause', (tester) async {
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        _job(
          DarkroomJobState.failed,
          errorText: 'the render engine stopped answering',
          note: 'Drafting Master · B',
        ),
      ],
    );

    await pumpNarrative(tester);

    final message = tester.widget<SkotiqBanner>(banner).message;
    expect(message, contains('It was Drafting Master · B when it stopped.'));
  });

  // A night whose masters arrived and whose Darkroom pass was never queued was
  // silent on this screen — the very state the banner's own rationale names.
  // The open-time recovery now makes that state a `queued` row, and this is
  // where the operator reads it.
  testWidgets('a queued pass says the night is still owed its drafts', (
    tester,
  ) async {
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        DarkroomJob(
          id: 51,
          sessionId: 1,
          kind: DarkroomJobKind.dawn,
          state: DarkroomJobState.queued,
          progress: 0.0,
          note: 'Queued at startup: the integration finished but the previous '
              'process exited before this pass was queued.',
          attempts: 0,
          createdAt: DateTime.utc(2026, 8, 16, 6),
        ),
      ],
    );

    await pumpNarrative(tester);

    expect(banner, findsOneWidget);
    final widget = tester.widget<SkotiqBanner>(banner);
    expect(widget.tone, BannerTone.warning);
    // The state is the banner's TITLE now (SkotiqBanner puts title and
    // message on one line, and the title names the problem); what is owed
    // stays in the message, which is the point of the banner.
    expect(widget.title, contains('queued'));
    expect(
      widget.message,
      contains(
        'The drafts, the night report, the delivery and the morning message',
      ),
      reason: 'what is owed is the point of the banner',
    );
    expect(
      widget.message,
      contains('the previous process exited before this pass was queued.'),
      reason: 'the row\'s own sentence, not a paraphrase of it',
    );
    expect(
      widget.message,
      isNot(contains('started 0 times')),
      reason: 'a pass nothing has picked up has no history to state',
    );
    expect(widget.message, isNot(contains('Process now')));
  });

  testWidgets('a queued pass that has been started before says so', (
    tester,
  ) async {
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        DarkroomJob(
          id: 52,
          sessionId: 1,
          kind: DarkroomJobKind.dawn,
          state: DarkroomJobState.queued,
          progress: 0.4,
          note: 'Re-queued: the previous process exited while this job was '
              'running.',
          attempts: 2,
          createdAt: DateTime.utc(2026, 8, 16, 6),
        ),
      ],
    );

    await pumpNarrative(tester);

    final message = tester.widget<SkotiqBanner>(banner).message;
    expect(message, contains('It has been started 2 times already.'));
  });

  testWidgets('a pass that ran to the end states it and routes to the drafts',
      (tester) async {
    when(() => jobs.listForSession(1))
        .thenAnswer((_) async => [_job(DarkroomJobState.done)]);

    await pumpNarrative(tester);

    expect(banner, findsNothing, reason: 'a completed pass is not a warning');
    expect(done, findsOneWidget);
    final widget = tester.widget<SkotiqBanner>(done);
    expect(widget.tone, BannerTone.success);
    expect(widget.message, contains('ran to the end'));
    expect(
      widget.message,
      contains('Open the Darkroom'),
      reason: 'the drafts had no route from any desktop surface',
    );
    expect(
      widget.message,
      isNot(contains('drafts ready')),
      reason: 'the row carries no count, so the banner states none',
    );
    expect(
      find.byKey(const ValueKey('session_review_darkroom_pass_open')),
      findsOneWidget,
      reason: 'naming the drafts without a way to them is the same silence',
    );
  });

  testWidgets('a completed pass names the hour its row recorded',
      (tester) async {
    when(() => jobs.listForSession(1))
        .thenAnswer((_) async => [_job(DarkroomJobState.done)]);

    await pumpNarrative(tester);

    // The row's `finishedAt` is 05:40 UTC; the sentence carries whatever that
    // is where the operator is standing, so the assertion is derived the same
    // way rather than hard-coding one machine's zone.
    final local = DateTime.utc(2026, 8, 16, 5, 40).toLocal();
    final hhmm = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    expect(tester.widget<SkotiqBanner>(done).message, contains(hhmm));
  });

  testWidgets('a completed pass with no session offers no route',
      (tester) async {
    // A job queued outside a session has no night to open, and a control that
    // navigated anyway would land on somebody else's masters.
    when(() => jobs.listForSession(1)).thenAnswer(
      (_) async => [
        DarkroomJob(
          id: 44,
          kind: DarkroomJobKind.manual,
          state: DarkroomJobState.done,
          progress: 1.0,
          attempts: 1,
          createdAt: DateTime.utc(2026, 8, 16, 6),
          finishedAt: DateTime.utc(2026, 8, 16, 6, 5),
        ),
      ],
    );

    await pumpNarrative(tester);

    expect(done, findsOneWidget);
    expect(
      find.byKey(const ValueKey('session_review_darkroom_pass_open')),
      findsNothing,
    );
  });

  testWidgets('a session with no pass adds nothing', (tester) async {
    when(() => jobs.listForSession(1)).thenAnswer((_) async => []);

    await pumpNarrative(tester);

    expect(banner, findsNothing);
  });

  testWidgets('the newest pass is the one reported', (tester) async {
    when(() => jobs.listForSession(1)).thenAnswer(
      // `listForSession` orders newest first, which is the order this reads.
      (_) async => [
        DarkroomJob(
          id: 43,
          sessionId: 1,
          kind: DarkroomJobKind.manual,
          state: DarkroomJobState.done,
          progress: 1.0,
          attempts: 1,
          createdAt: DateTime.utc(2026, 8, 16, 6),
        ),
        _job(DarkroomJobState.failed, errorText: 'the older attempt failed'),
      ],
    );

    await pumpNarrative(tester);

    expect(
      banner,
      findsNothing,
      reason: 'the re-run is the operator\'s answer to the failure, and it '
          'succeeded',
    );
    expect(done, findsOneWidget, reason: 'and the re-run states its own end');
  });
}

/// A tiny on-disk PNG for the seeded hero to load.
Future<String> _writeSamplePng() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = const Color(0xFF223344),
  );
  final image = await recorder.endRecording().toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = await Directory.systemTemp.createTemp('sk_review_pass_');
  final file = File('${dir.path}/preview.png');
  await file.writeAsBytes(Uint8List.view(data!.buffer));
  return file.path;
}
