// The whole night-end chain, from the dawn park to the morning message, over
// a target imaged on several nights: calibration, the multi-night build, the
// fold of a new night into it, delivery, the message and its deep link, and
// the run and the builds coming back after a restart.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/auto_integration_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'night_end_fakes.dart';

void main() {
  late SkotiqDatabase db;
  late Directory folder;
  late Directory drop;
  late FakeBuildNative native;
  late RecordingNotifications notifications;
  late InstantCalibration calibration;
  late int target;
  var run = 10;
  var generation = 0;

  ProviderContainer launch() {
    final container = ProviderContainer(
      overrides: nightEndOverrides(
        db: db,
        native: native,
        notifications: notifications,
        calibration: calibration,
        mastersRoot: Directory('${folder.path}/Masters'),
      ),
    );
    addTearDown(container.dispose);
    container.read(autoIntegrationCoordinatorProvider);
    return container;
  }

  /// One night of [filters], two 120 s subs each, in its own session. The
  /// subs of the night that is ending carry its run id.
  Future<int> night(
    DateTime evening,
    List<String> filters, {
    int? runId,
  }) async {
    final session = await db.into(db.imagingSessions).insert(
          ImagingSessionsCompanion.insert(startTime: evening),
        );
    for (final filter in filters) {
      for (var i = 0; i < 2; i++) {
        final at = evening.add(Duration(hours: 2, minutes: 10 * i));
        final name = '${filter}_${evening.day}_$i.fits';
        await File('${folder.path}/$name').writeAsString('raw');
        final id = await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            targetId: Value(target),
            sessionId: Value(session),
            filePath: '${folder.path}/$name',
            fileName: name,
            exposureDuration: 120,
            filter: Value(filter),
            sensorTemp: const Value(-10),
            capturedAt: at,
          ),
        );
        if (runId != null) {
          await db.imagesDao.stampProducingNode(
            imageId: id,
            producingNodeId: 'expose',
            producingRunId: '$runId',
          );
        }
      }
    }
    return session;
  }

  /// The dawn park ends the run of [session].
  void dawnEnds(ProviderContainer container, int session, int runId) {
    container.read(sequenceStopEvidenceProvider.notifier).state =
        const SequenceStopDecision(
      SequenceStopAuthor.system,
      origin: 'dawn_approaching',
      parked: true,
    );
    container.read(sequenceTerminalRunResultProvider.notifier).state =
        SequenceTerminalRunResult(
      generation: ++generation,
      outcome: SequenceExecutionState.idle,
      runStatus: 'aborted',
      runId: runId,
      dbSessionId: session,
    );
  }

  Future<NightEndRun> nightEndRun(
      ProviderContainer container, int count) async {
    await settle(() {
      final runs = container.read(nightEndRunsProvider);
      return runs.length >= count && runs.first.finished;
    });
    final runs = container.read(nightEndRunsProvider);
    expect(runs, hasLength(count));
    expect(runs.first.finished, isTrue);
    return runs.first;
  }

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    folder = await Directory.systemTemp.createTemp('skotiq-night-end-');
    drop = await Directory('${folder.path}/nas').create();
    native = FakeBuildNative();
    notifications = RecordingNotifications();
    calibration = InstantCalibration();
    target = await db.targetsDao.createTarget(
      TargetsCompanion.insert(name: 'NGC891', ra: 2.4, dec: 42.3),
    );
    await DeliveryTargetsDao(db).create(
      name: 'nas',
      kind: ArtifactDestinationKind.watchedFolder,
      configJson: jsonEncode({'path': drop.path}),
      content: const {
        ArtifactContent.linearMasters,
        ArtifactContent.draftRender,
        ArtifactContent.nightReport,
      },
    );
    await db.settingsDao
        .setSetting(NightEndAutomationSettings.buildKey, 'true');
  });

  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });

  test(
      'a dawn end calibrates, builds the target from all its nights, '
      'delivers, and sends one morning message that opens the target; the '
      'next night folds in and only its filter is rebuilt', () async {
    await night(DateTime(2026, 10, 21, 20), ['L', 'R']);
    await night(DateTime(2026, 10, 22, 20), ['L', 'R']);
    final tonight = await night(
      DateTime(2026, 10, 23, 20),
      ['L', 'R'],
      runId: ++run,
    );
    final app = launch();
    dawnEnds(app, tonight, run);

    final first = await nightEndRun(app, 1);
    expect(calibration.reasons, ['dawn ended imaging']);
    expect(first.reason, 'dawn ended imaging');
    expect(first.calibrate.state, NightEndStepState.done);
    expect(first.calibrate.detail, contains('20 darks'));
    final ngc = first.targets.single;
    expect(ngc.target, 'NGC891');
    expect(ngc.nights, 3);
    expect(ngc.build.state, NightEndStepState.done);
    expect(ngc.build.detail, contains('3 nights, 12 subs used'));
    expect(ngc.deliver.state, NightEndStepState.done);
    expect(ngc.deliver.detail, startsWith('Delivered'));
    expect(first.message.state, NightEndStepState.done);
    expect(ngc.directory, '${folder.path}/Masters/NGC891');

    expect(native.built, ['L', 'R']);
    for (final build in native.requests.where((r) => r['op'] == 'build')) {
      final lights = [
        for (final g in build['groups'] as List) ...g['lights'] as List,
      ];
      expect(lights, hasLength(6), reason: 'every night of ${build['filter']}');
    }
    expect(drop.listSync(recursive: true).whereType<File>(), isNotEmpty);

    expect(notifications.sent, hasLength(1),
        reason: 'one morning message for the night, nothing per step');
    final message = notifications.sent.single;
    expect(message.title, 'Masters ready: NGC891');
    expect(message.message, contains('3 nights'));
    expect(message.message, contains('Delivered'));
    expect(message.deepLink, 'darkroom_target:NGC891');
    expect(
      darkroomRouteForPayload(message.deepLink!),
      '/darkroom?tab=targets&target=NGC891',
    );
    expect(
      app.read(autoIntegrationCompletionProvider)!.result.message,
      'NGC891: masters ready from 3 nights.',
    );

    // The next night images L only: it folds into the same build.
    final next = await night(
      DateTime(2026, 10, 24, 20),
      ['L'],
      runId: ++run,
    );
    native.requests.clear();
    dawnEnds(app, next, run);
    final second = await nightEndRun(app, 2);
    expect(native.built, ['L', 'R', 'L'], reason: 'R had no new subs');
    final rebuilt = native.requests.singleWhere((r) => r['op'] == 'build');
    expect(
      [for (final g in rebuilt['groups'] as List) ...g['lights'] as List],
      hasLength(8),
    );
    expect(second.targets.single.nights, 4);
    expect(second.targets.single.directory, ngc.directory);
    expect(notifications.sent.last.message, contains('4 nights'));

    // After a restart the history and the last build are still there.
    final later = launch();
    await later.read(nightEndRunnerProvider).start();
    expect(later.read(nightEndRunsProvider), hasLength(2));
    expect(later.read(nightEndRunsProvider).first.targets.single.nights, 4);
    final job = later.read(darkroomBuildJobsProvider)!;
    expect(job.stage, DarkroomJobStage.done);
    expect(job.target, 'NGC891');
  });

  test(
      'a build held at the framing check survives a restart, opens from '
      'the message, and is delivered and announced once accepted', () async {
    await night(DateTime(2026, 10, 21, 20), ['L', 'R']);
    final tonight = await night(
      DateTime(2026, 10, 22, 20),
      ['L', 'R'],
      runId: ++run,
    );
    native.retained = .55;
    native.limiting = [
      {
        'path': '${folder.path}/R_22_1.fits',
        'group': 'n',
        'retainedWithout': .91,
      },
    ];
    final app = launch();
    dawnEnds(app, tonight, run);
    final held = await nightEndRun(app, 1);
    expect(held.targets.single.build.state, NightEndStepState.waiting);
    expect(held.targets.single.build.detail, contains('R_22_1.fits'));
    expect(native.built, isEmpty);
    final message = notifications.sent.single;
    expect(message.title, 'Masters wait for the framing check: NGC891');
    expect(message.deepLink, 'darkroom_framing:NGC891');
    expect(
      darkroomRouteForPayload(message.deepLink!),
      '/darkroom?tab=targets&target=NGC891&view=framing',
    );
    await app.read(darkroomBuildJobsProvider.notifier).flush();
    await app.read(nightEndRunnerProvider).idle();

    // Skotiq restarts before anyone looks.
    final later = launch();
    await later.read(nightEndRunnerProvider).start();
    final jobs = later.read(darkroomBuildJobsProvider.notifier);
    final review = jobs.reviewHeld('NGC891')!;
    expect(review.stage, DarkroomJobStage.awaitingReview);
    expect(review.nightRunId, held.id);
    await jobs.setMinRetainedArea(.5);
    await jobs.accept();
    await settle(
      () =>
          later.read(nightEndRunsProvider).first.targets.single.deliver.state ==
          NightEndStepState.done,
    );
    final after = later.read(nightEndRunsProvider).first;
    expect(after.targets.single.build.state, NightEndStepState.done);
    expect(after.targets.single.deliver.state, NightEndStepState.done);
    await settle(() => notifications.sent.length == 2);
    expect(notifications.sent.last.title, 'Masters ready: NGC891');
    expect(notifications.sent.last.deepLink, 'darkroom_target:NGC891');
  });

  test(
      'a night-end run cut short by a restart carries on at the next '
      'launch', () async {
    await night(DateTime(2026, 10, 21, 20), ['L']);
    final tonight = await night(DateTime(2026, 10, 22, 20), ['L']);
    await DarkroomStateStore(db).write(nightEndRunsStateKey, {
      'runs': [
        NightEndRun(
          id: 'night-cut-short',
          sessionId: tonight,
          startedAt: DateTime(2026, 10, 23, 6),
          reason: 'dawn ended imaging',
          calibrate: const NightEndStep(NightEndStepState.done),
          targets: const [
            NightEndTarget(
              target: 'NGC891',
              build: NightEndStep(NightEndStepState.running),
            ),
          ],
        ).toJson(),
      ],
    });
    final app = launch();
    final run = await nightEndRun(app, 1);
    expect(run.id, 'night-cut-short');
    expect(run.targets.single.build.state, NightEndStepState.done);
    expect(run.targets.single.nights, 2);
    expect(run.targets.single.deliver.state, NightEndStepState.done);
    expect(notifications.sent.single.title, 'Masters ready: NGC891');
  });

  test(
      'with every step but the build switched off, the run says so and '
      'sends nothing', () async {
    await db.settingsDao
        .setSetting(NightEndAutomationSettings.calibrateKey, 'false');
    await db.settingsDao
        .setSetting(NightEndAutomationSettings.deliverKey, 'false');
    await db.settingsDao.setSetting(
      NightEndAutomationSettings.morningMessageKey,
      'false',
    );
    final tonight = await night(
      DateTime(2026, 10, 22, 20),
      ['L'],
      runId: ++run,
    );
    final app = launch();
    dawnEnds(app, tonight, run);
    final result = await nightEndRun(app, 1);
    expect(calibration.reasons, isEmpty);
    expect(result.calibrate.state, NightEndStepState.skipped);
    expect(result.targets.single.build.state, NightEndStepState.done);
    expect(result.targets.single.deliver.state, NightEndStepState.skipped);
    expect(result.message.state, NightEndStepState.skipped);
    expect(notifications.sent, isEmpty);
    expect(drop.listSync(recursive: true), isEmpty);
  });

  test(
      'a build still held when the next night ends is folded into that '
      'night\'s build', () async {
    final first = await night(
      DateTime(2026, 10, 21, 20),
      ['L'],
      runId: ++run,
    );
    native.retained = .55;
    final app = launch();
    dawnEnds(app, first, run);
    final held = await nightEndRun(app, 1);
    expect(held.targets.single.build.state, NightEndStepState.waiting);

    native.retained = .9;
    final second = await night(
      DateTime(2026, 10, 22, 20),
      ['L'],
      runId: ++run,
    );
    dawnEnds(app, second, run);
    final built = await nightEndRun(app, 2);
    expect(built.targets.single.build.state, NightEndStepState.done);
    expect(built.targets.single.nights, 2);
    final earlier =
        app.read(nightEndRunsProvider).singleWhere((r) => r.id == held.id);
    expect(earlier.targets.single.build.state, NightEndStepState.skipped);
    expect(earlier.targets.single.build.detail, contains('Folded'));
    expect(app.read(darkroomHeldBuildsProvider), isEmpty);
    expect(app.read(darkroomBuildJobsProvider)!.stage, DarkroomJobStage.done);
  });
}
