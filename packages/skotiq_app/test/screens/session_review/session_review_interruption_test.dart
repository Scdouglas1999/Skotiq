// A post-session pass a PROCESS EXIT cut off has to be visible on the session
// it ran on.
//
// `DarkroomPassBanner` covers a pass that reached an ending — `failed` or
// `cancelled` on its own row. A pass the machine died inside reaches no ending:
// the row is simply still `running` when the process stops existing, and the
// open-time recovery discovers it hours later in `beforeOpen`. What that
// recovery wrote went to the session's notes and a `warning` Night Narrator
// event, and Session Review renders neither — so the operator opened the night,
// saw the masters and the score, and had nothing telling them the drafting, the
// night report and the delivery had been cut off mid-run.
//
// Driven through the REAL narrator row: the event is seeded into the same
// in-memory database the controller loads from, so what these pin is the whole
// path from the row the recovery writes to the sentence on screen.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/session_interruption_banner.dart';
import 'package:skotiq_app/screens/session_review/workbench_view.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import 'seeded_review_fixture.dart';

class _MockJobs extends Mock implements DarkroomJobsDao {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late String previewPath;
  late _MockJobs jobs;

  setUp(() async {
    db = mockDatabase();
    previewPath = await _writeSamplePng();
    jobs = _MockJobs();
    when(() => jobs.listForSession(any())).thenAnswer((_) async => []);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seed the row the open-time recovery writes for an interrupted night.
  Future<void> seedEvent({
    required int sessionId,
    String eventType = kInterruptedPassEventType,
    String headline = 'The Darkroom pass was interrupted before it finished.',
    String? body =
        'Skotiq closed while Darkroom job #7 was drafting this session, '
            '40% of the way through.',
    DateTime? at,
  }) async {
    await db.customInsert(
      'INSERT INTO imaging_sessions(id, start_time, status) VALUES (?, ?, ?) '
      'ON CONFLICT(id) DO NOTHING',
      variables: [
        Variable<int>(sessionId),
        Variable<int>(DateTime.utc(2026, 8, 16).millisecondsSinceEpoch ~/ 1000),
        const Variable<String>('completed'),
      ],
    );
    await db.customInsert(
      'INSERT INTO narrator_events('
      'session_id, timestamp, event_type, category, severity, headline, '
      'body, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(sessionId),
        Variable<int>(
          (at ?? DateTime.utc(2026, 8, 17, 6)).millisecondsSinceEpoch ~/ 1000,
        ),
        Variable<String>(eventType),
        const Variable<String>('quality'),
        const Variable<String>('warning'),
        Variable<String>(headline),
        Variable<String>(body),
        Variable<String>('$eventType:${at ?? DateTime.utc(2026, 8, 17, 6)}'),
      ],
    );
  }

  final banner = find.byKey(
    const ValueKey('session_review_interruption_banner'),
  );

  Future<void> pump(
    WidgetTester tester, {
    SessionReviewScope scope = const SessionReviewScope.session(1),
    bool workbench = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
          home: Scaffold(
            body: workbench
                ? WorkbenchView(scope: scope)
                : NarrativeView(scope: scope),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('an interrupted pass states itself in the narrative view', (
    tester,
  ) async {
    await seedEvent(sessionId: 1);

    await pump(tester);

    expect(banner, findsOneWidget);
    final widget = tester.widget<SkotiqBanner>(banner);
    expect(widget.tone, BannerTone.warning);
    expect(widget.message, contains('interrupted before it finished'));
    expect(
      widget.message,
      contains('40% of the way through'),
      reason: 'the detector\'s own body is what the screen says',
    );
  });

  testWidgets('the workbench view states it too', (tester) async {
    await seedEvent(sessionId: 1);

    await pump(tester, workbench: true);

    expect(banner, findsOneWidget);
  });

  testWidgets('the newest interruption is the one stated', (tester) async {
    await seedEvent(
      sessionId: 1,
      headline: 'The post-session integration was interrupted.',
      body: 'the older one',
      at: DateTime.utc(2026, 8, 16, 6),
    );
    await seedEvent(
      sessionId: 1,
      body: 'the newer one',
      at: DateTime.utc(2026, 8, 17, 6),
    );

    await pump(tester);

    final widget = tester.widget<SkotiqBanner>(banner);
    expect(widget.message, contains('the newer one'));
    expect(widget.message, isNot(contains('the older one')));
  });

  testWidgets('an uninterrupted night adds nothing', (tester) async {
    await seedEvent(
      sessionId: 1,
      eventType: 'quality.focus_drift',
      headline: 'Focus drifted as the night cooled.',
      body: null,
    );

    await pump(tester);

    expect(banner, findsNothing);
  });

  testWidgets('another night\'s interruption does not claim this one', (
    tester,
  ) async {
    await seedEvent(sessionId: 2);

    await pump(tester);

    expect(banner, findsNothing);
  });

  testWidgets('a target-scoped review has no one night to state', (
    tester,
  ) async {
    await seedEvent(sessionId: 1);

    await pump(tester, scope: const SessionReviewScope.target(5));

    expect(banner, findsNothing);
  });

  group('the banner itself', () {
    testWidgets('renders nothing for a night that was never interrupted', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionInterruptionBanner(notice: null)),
        ),
      );

      expect(banner, findsNothing);
    });

    testWidgets('states the recovery\'s sentence unchanged', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SessionInterruptionBanner(
              notice: 'The Darkroom pass was interrupted before it finished. '
                  'The job is re-queued.',
            ),
          ),
        ),
      );

      expect(
        tester.widget<SkotiqBanner>(banner).message,
        'The Darkroom pass was interrupted before it finished. The job is '
        're-queued.',
      );
    });
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
  final dir = await Directory.systemTemp.createTemp('sk_review_interrupt_');
  final file = File('${dir.path}/preview.png');
  await file.writeAsBytes(Uint8List.view(data!.buffer));
  return file.path;
}
