// The Darkroom's Activity tab over realistic saved state: a running build, a
// build held at the framing check, night-end runs with each step's outcome,
// the integration passes, and the night-end automation switches.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/activity/activity_tab.dart';
import 'package:skotiq_app/screens/settings/delivery_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/mock_database.dart';
import '../../../harness/pump_app_screen.dart' show TestBackendNotifier;

/// The build jobs with a fixed current job and a recorded Stop.
class _Jobs extends DarkroomBuildJobs {
  _Jobs(this.initial);

  final DarkroomBuildJob? initial;
  var stops = 0;

  @override
  DarkroomBuildJob? build() => initial;

  @override
  Future<void> stop() async => stops++;
}

DarkroomBuildPlan _plan() => DarkroomBuildPlan.fromJson({
      'version': 1,
      'target': 'M81',
      'referencePath': '/d/L_1.fits',
      'minOverlap': .95,
      'maxEccentricity': .65,
      'groups': [
        {
          'label': 'Night of 2026-10-23 · L',
          'filter': 'L',
          'calibration': <String, dynamic>{},
          'lights': [
            {'id': 1, 'path': '/d/L_1.fits', 'exposureSec': 120.0},
            {'id': 2, 'path': '/d/L_2.fits', 'exposureSec': 120.0},
          ],
        },
      ],
    });

DarkroomRegistrationPreview _preview() => DarkroomRegistrationPreview.fromJson({
      'width': 100,
      'height': 80,
      'frames': [
        {'path': '/d/L_1.fits', 'group': 'n', 'included': true},
        {'path': '/d/L_2.fits', 'group': 'n', 'included': true},
      ],
      'crop': [2, 2, 60, 50],
      'retainedArea': .62,
      'minRetainedArea': .8,
      'meetsMinimum': false,
      'limiting': [
        {'path': '/d/L_2.fits', 'group': 'n', 'retainedWithout': .93},
      ],
    });

NightEndRun _night() => NightEndRun(
      id: 'night-1',
      sessionId: 4,
      startedAt: DateTime(2026, 10, 24, 5, 21),
      finishedAt: DateTime(2026, 10, 24, 6, 40),
      reason: 'dawn ended imaging',
      calibrate: const NightEndStep(
        NightEndStepState.done,
        'Took 20 darks and 50 bias frames and built their masters.',
      ),
      targets: const [
        NightEndTarget(
          target: 'NGC 891',
          nights: 4,
          build: NightEndStep(
            NightEndStepState.done,
            '4 nights, 345 subs used, 12 left out.',
          ),
          deliver: NightEndStep(
            NightEndStepState.done,
            'Delivered 14 files to 1 destination.',
          ),
        ),
        NightEndTarget(
          target: 'M81',
          nights: 2,
          build: NightEndStep(
            NightEndStepState.waiting,
            'The common crop keeps 62.0% of the field (minimum 80%). It waits '
            'for you at the framing check.',
          ),
        ),
      ],
      message: const NightEndStep(
        NightEndStepState.done,
        'Night end: 1 target built, 1 waiting for you',
      ),
    );

void main() {
  late SkotiqDatabase db;
  late List<String> visited;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    DarkroomBuildJob? job,
    Size size = const Size(1800, 1000),
    String location = '/darkroom?tab=activity',
    List<PassRecordSummary> passes = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    visited = [];
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend()),
        ),
        databaseProvider.overrideWithValue(db),
        darkroomBuildJobsProvider.overrideWith(() => _Jobs(job)),
        darkroomPassRecordsProvider.overrideWith(
          (ref) => Stream.value(passes),
        ),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
        watchedFolderExistsProvider.overrideWithValue((_) async => true),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/darkroom',
          builder: (context, state) {
            visited.add(state.uri.toString());
            return const Scaffold(body: DarkroomActivityTab());
          },
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) {
            visited.add(state.uri.toString());
            return const Scaffold(body: Text('Settings'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  setUp(() {
    db = mockDatabase();
  });
  tearDown(() => db.close());

  testWidgets('with nothing to show, every panel says so in words', (
    tester,
  ) async {
    await pump(tester, size: const Size(1280, 900));
    expect(find.textContaining('No build is running.'), findsOneWidget);
    expect(find.textContaining('Nothing is waiting.'), findsOneWidget);
    expect(
      find.textContaining('No night has ended with the automation on yet.'),
      findsOneWidget,
    );
    expect(find.text('Night-end automation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running build shows its stage, subs, time left and Stop', (
    tester,
  ) async {
    final container = await pump(
      tester,
      job: DarkroomBuildJob(
        target: 'NGC 891',
        stage: DarkroomJobStage.building,
        message: 'Building R',
        startedAt: DateTime(2026, 10, 24, 5, 30),
        nightRunId: 'night-1',
        filter: 'R',
        filterIndex: 1,
        filterCount: 4,
        overallDone: 120,
        overallTotal: 345,
        eta: const Duration(minutes: 72),
      ),
    );
    expect(find.text('Building R (2 of 4)'), findsOneWidget);
    expect(find.text('120 of 345 subs'), findsOneWidget);
    expect(find.text('About 1 h 12 min left'), findsOneWidget);
    expect(
      find.textContaining('Started by the night-end automation'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('darkroom_activity_stop')));
    await tester.pump();
    expect(
      (container.read(darkroomBuildJobsProvider.notifier) as _Jobs).stops,
      1,
    );
  });

  testWidgets(
      'a held build is listed with the field it keeps and opens the '
      'framing check', (tester) async {
    await pump(
      tester,
      job: DarkroomBuildJob(
        target: 'M81',
        stage: DarkroomJobStage.awaitingReview,
        message: 'held',
        startedAt: DateTime(2026, 10, 24, 5, 40),
        nightRunId: 'night-1',
        plan: _plan(),
        preview: _preview(),
        directory: '/m/M81',
      ),
    );
    expect(find.text('62.0% kept, 80% needed'), findsOneWidget);
    expect(find.textContaining('1 frame limit the field'), findsOneWidget);
    expect(
      find.textContaining('Held by the night-end build of Oct 23 to 24'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('darkroom_activity_open_framing_M81')),
    );
    await tester.pumpAndSettle();
    expect(visited.last, '/darkroom?tab=targets&target=M81&view=framing');
  });

  testWidgets(
      'the night-end history lists every step with its outcome, and '
      'each target opens its page or its framing check', (tester) async {
    await DarkroomStateStore(db).write(nightEndRunsStateKey, {
      'runs': [_night().toJson()],
    });
    await pump(tester);

    expect(find.text('Oct 23 to 24'), findsOneWidget);
    expect(find.text('dawn ended imaging'), findsOneWidget);
    final history = find.byKey(const ValueKey('darkroom_activity_history'));
    for (final step in ['Calibrate', 'Build', 'Deliver', 'Morning message']) {
      expect(
        find.descendant(of: history, matching: find.text(step)),
        findsOneWidget,
        reason: step,
      );
    }
    expect(find.textContaining('Took 20 darks'), findsOneWidget);
    expect(find.text('Delivered 14 files to 1 destination.'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('^Calibrate: Done')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Build: Waits for you')), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Open the framing check'));
    await tester.pumpAndSettle();
    expect(visited.last, '/darkroom?tab=targets&target=M81&view=framing');
  });

  testWidgets('a pass opens inside Activity and Back returns to the lists', (
    tester,
  ) async {
    await pump(
      tester,
      passes: [
        PassRecordSummary(
          runId: 'post-session-7',
          path: '/x/pass.json',
          startedAt: DateTime(2026, 10, 22, 6),
          ended: true,
          target: 'NGC 891',
        ),
      ],
    );
    await tester.tap(
      find.byKey(const ValueKey('darkroom_activity_pass_post-session-7')),
    );
    await tester.pump();
    await tester.pump();
    expect(visited.last, '/darkroom?tab=activity&pass=post-session-7');
    expect(find.text('Integration pass'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('darkroom_activity_pass_back')));
    await tester.pumpAndSettle();
    expect(visited.last, '/darkroom?tab=activity');
    expect(find.text('Night-end automation'), findsOneWidget);
  });

  group('night-end automation', () {
    testWidgets(
        'a fresh install takes darks and bias, builds nothing, and '
        'says why the later steps are off', (tester) async {
      await pump(tester);
      SkotiqSwitch toggle(String key) =>
          tester.widget<SkotiqSwitch>(find.byKey(ValueKey(key)));
      expect(toggle('night_end_calibrate').value, isTrue);
      expect(toggle('night_end_build').value, isFalse);
      expect(toggle('night_end_deliver').enabled, isFalse);
      expect(
        find.textContaining('Needs Build masters.'),
        findsOneWidget,
      );
      expect(find.text('80%'), findsOneWidget);
    });

    testWidgets('each switch writes the setting the night-end run reads', (
      tester,
    ) async {
      await pump(tester);
      Future<void> flip(String key) async {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)));
        // The write and the re-read are real database work.
        for (var i = 0; i < 2; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }
      }

      await flip('night_end_build');
      await flip('night_end_deliver');
      await flip('night_end_message');
      await flip('night_end_calibrate');
      final settings = await NightEndAutomationSettings.load(db.settingsDao);
      expect(settings.build, isTrue);
      expect(settings.deliver, isFalse);
      expect(settings.morningMessage, isFalse);
      expect(settings.calibrate, isFalse);
      expect(
        await db.settingsDao.getSetting('end_of_night_calibration.enabled'),
        'false',
        reason: 'the same switch as Settings > End-of-night calibration',
      );
    });

    testWidgets(
        'the delivery and notification lines state their live '
        'values', (tester) async {
      await db.settingsDao.setSetting('notifications_enabled', 'false');
      await db.settingsDao
          .setSetting(NightEndAutomationSettings.buildKey, 'true');
      await pump(tester);
      expect(
        find.textContaining('No destination is set up, so the files stay on '
            'this computer.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Notifications are off in Settings'),
        findsOneWidget,
      );
    });
  });

  for (final size in const [
    Size(1280, 800),
    Size(1800, 1000),
    Size(700, 900)
  ]) {
    testWidgets('lays out without overflow at ${size.width.toInt()} px', (
      tester,
    ) async {
      await DarkroomStateStore(db).write(nightEndRunsStateKey, {
        'runs': [_night().toJson()],
      });
      await pump(
        tester,
        size: size,
        job: DarkroomBuildJob(
          target: 'A target with a long catalog name, NGC 7000 North America',
          stage: DarkroomJobStage.stopped,
          message: 'Interrupted when Skotiq closed. Resume keeps the finished '
              'filters.',
          startedAt: DateTime(2026, 10, 24, 5),
          finishedAt: DateTime(2026, 10, 24, 5, 50),
          directory: '/nowhere',
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('The build stopped'), findsOneWidget);
    });
  }
}
