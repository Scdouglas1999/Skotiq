import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'darkroom_fake_native.dart';

class _Seam extends Fake implements PostSessionSeam {
  final events =
      StreamController<({String phase, double fraction})>.broadcast();
  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      events.stream;
}

class _Notifications extends NotificationService {
  _Notifications() : super.testing(settingsReader: () => null);
  final sent = <String>[];
  final links = <String?>[];
  @override
  Future<bool> notify({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    sent.add('$title | $message');
    links.add(deepLink);
    return true;
  }

  final detailed = <String>[];
  @override
  Future<NotificationDispatch> notifyDetailed({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    detailed.add('$title | $message');
    return const NotificationDispatch(routed: null, webhookAccepted: true);
  }
}

void main() {
  late SkotiqDatabase db;
  late Directory folder;
  late FakeDarkroomNative native;
  late _Seam seam;
  late _Notifications notifications;
  late ProviderContainer container;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    folder = await Directory.systemTemp.createTemp('skotiq-jobs-');
    final target = await db.targetsDao.createTarget(
      TargetsCompanion.insert(name: 'NGC891', ra: 2.3, dec: 42.3),
    );
    for (final f in ['L', 'R']) {
      for (var i = 0; i < 3; i++) {
        final file = File('${folder.path}/${f}_$i.fits');
        await file.writeAsString('raw');
        await db.imagesDao.createImage(
          CapturedImagesCompanion.insert(
            targetId: Value(target),
            filePath: file.path,
            fileName: '${f}_$i.fits',
            exposureDuration: 120,
            filter: Value(f),
            sensorTemp: const Value(-10),
            capturedAt: DateTime(2026, 10, 22, 22 + i),
          ),
        );
      }
    }
    native = FakeDarkroomNative(const {});
    seam = _Seam();
    notifications = _Notifications();
    final service = DarkroomBuildService(
      operation: native.call,
      library: CalibrationLibraryService(
        db: db,
        flatLibraryDao: FlatLibraryDao(db),
        tagsDao: CalibrationTagsDao(db),
      ),
      masters: IntegratedMastersDao(db),
      readHeader: (_) async => {'NAXIS1': '100', 'NAXIS2': '80'},
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        darkroomBuildServiceProvider.overrideWithValue(service),
        postSessionSeamProvider.overrideWithValue(seam),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await folder.delete(recursive: true);
  });

  Future<DarkroomBuildPlan> planFor() async {
    final service = container.read(darkroomBuildServiceProvider);
    final frames = (await loadDarkroomTargets(
      db,
      readHeader: (_) async => const {},
    ))['NGC891']!;
    final groups = await service.prepare(frames);
    return service.plan(
      target: 'NGC891',
      groups: groups,
      referencePath: DarkroomBuildService.chooseReference(groups),
    );
  }

  test(
    'the pre-pass waits for review and exclusions update the plan',
    () async {
      final jobs = container.read(darkroomBuildJobsProvider.notifier);
      final plan = await planFor();
      await jobs.checkFraming(target: 'NGC891', plan: plan);
      var job = container.read(darkroomBuildJobsProvider)!;
      expect(job.stage, DarkroomJobStage.awaitingReview);
      expect(job.preview!.frames, hasLength(6));

      final r2 = plan.lights.firstWhere(
        (l) => '${l['path']}'.endsWith('R_2.fits'),
      );
      await jobs.exclude({r2['path'] as String: 'Limits the crop'});
      job = container.read(darkroomBuildJobsProvider)!;
      expect(job.plan!.lights, hasLength(5));
      expect(job.preview!.frames, hasLength(5));
      expect(native.requests.last['gridSize'], [100, 80]);
      expect(native.built, isEmpty, reason: 'nothing integrates before accept');
    },
  );

  test('a light put back is re-evaluated from its known footprint', () async {
    final jobs = container.read(darkroomBuildJobsProvider.notifier);
    final plan = await planFor();
    await jobs.checkFraming(target: 'NGC891', plan: plan);
    final first = container.read(darkroomBuildJobsProvider)!.preview!;
    final r2 =
        plan.lights.firstWhere(
              (l) => '${l['path']}'.endsWith('R_2.fits'),
            )['path']
            as String;
    await jobs.exclude({r2: 'Limits the crop'});
    expect(
      container.read(darkroomBuildJobsProvider)!.plan!.lights,
      hasLength(5),
    );

    await jobs.replan(plan, known: first);
    final job = container.read(darkroomBuildJobsProvider)!;
    expect(job.stage, DarkroomJobStage.awaitingReview);
    expect(job.plan!.lights, hasLength(6));
    expect(job.preview!.frames, hasLength(6));
    expect(
      native.requests.last['gridSize'],
      [100, 80],
      reason: 'every footprint was known, so nothing registered again',
    );
    expect(native.built, isEmpty);
  });

  test(
    'replan does nothing unless a build waits at the framing check',
    () async {
      final jobs = container.read(darkroomBuildJobsProvider.notifier);
      await jobs.replan(await planFor());
      expect(container.read(darkroomBuildJobsProvider), isNull);
      expect(native.requests, isEmpty);
    },
  );

  test(
    'an accepted build runs in the background with progress, ETA and the current frame',
    () async {
      final jobs = container.read(darkroomBuildJobsProvider.notifier);
      await jobs.checkFraming(target: 'NGC891', plan: await planFor());
      native.buildGate = Completer<void>();
      final running = jobs.accept(Directory('${folder.path}/out'));
      await native.buildStarted.future;
      var job = container.read(darkroomBuildJobsProvider)!;
      expect(job.stage, DarkroomJobStage.building);
      expect(job.filter, 'L');
      expect(job.overallTotal, 6);
      expect(job.framesTotal, 3);

      seam.events.add((phase: 'registering', fraction: 2 / 3));
      await Future<void>.delayed(Duration.zero);
      job = container.read(darkroomBuildJobsProvider)!;
      expect(job.framesDone, 2);
      expect(job.overallDone, 2);
      expect(job.eta, isNotNull);
      final l2 = (await db.imagesDao.getAllImages()).firstWhere(
        (f) => f.fileName == 'L_2.fits',
      );
      expect(job.currentImageId, l2.id);

      native.buildGate!.complete();
      await running;
      job = container.read(darkroomBuildJobsProvider)!;
      expect(job.stage, DarkroomJobStage.done);
      expect(job.report!['results'], hasLength(2));
      expect(notifications.sent.single, startsWith('Masters ready: NGC891'));
    },
  );

  test('build progress counts only the subs the crop keeps', () async {
    native.underOverlap = {'L_0.fits', 'L_1.fits', 'R_2.fits'};
    final jobs = container.read(darkroomBuildJobsProvider.notifier);
    await jobs.checkFraming(target: 'NGC891', plan: await planFor());
    expect(
      container.read(darkroomBuildJobsProvider)!.plan!.lights,
      hasLength(6),
    );
    native.buildGate = Completer<void>();
    final running = jobs.accept(Directory('${folder.path}/out'));
    await native.buildStarted.future;
    var job = container.read(darkroomBuildJobsProvider)!;
    expect(job.overallTotal, 3, reason: 'six planned, three kept');
    expect(job.filter, 'L');
    expect(job.framesTotal, 1);

    seam.events.add((phase: 'registering', fraction: 1));
    await Future<void>.delayed(Duration.zero);
    job = container.read(darkroomBuildJobsProvider)!;
    expect(job.framesDone, 1);
    expect(job.overallDone, 1);

    native.buildGate!.complete();
    await running;
    job = container.read(darkroomBuildJobsProvider)!;
    expect(job.overallDone, 3);
    expect(job.overallTotal, 3);
  });

  test('an unattended build counts only the subs the crop keeps', () async {
    native.underOverlap = {'R_0.fits'};
    native.buildGate = Completer<void>();
    final running = container
        .read(darkroomBuildJobsProvider.notifier)
        .startUnattended(
          'NGC891',
          outputRoot: Directory('${folder.path}/auto'),
        );
    await native.buildStarted.future;
    final job = container.read(darkroomBuildJobsProvider)!;
    expect(job.overallTotal, 5);
    native.buildGate!.complete();
    expect((await running).stage, DarkroomJobStage.done);
  });

  test(
    'unattended builds every filter of a target from all its nights',
    () async {
      final job = await container
          .read(darkroomBuildJobsProvider.notifier)
          .startUnattended(
            'NGC891',
            outputRoot: Directory('${folder.path}/auto'),
          );
      expect(job.stage, DarkroomJobStage.done);
      expect(job.unattended, isTrue);
      expect(native.built, ['L', 'R']);
      expect(notifications.sent.single, contains('Masters ready: NGC891'));
      expect(notifications.sent.single, contains('No filter has flats (L, R)'));
      expect(notifications.links.single, 'darkroom_target:NGC891');
      expect(job.directory, '${folder.path}/auto/NGC891');
    },
  );

  test(
    'unattended waits for review below the minimum and names the limiting frames',
    () async {
      native.retained = .55;
      native.limiting = [
        {'path': '/d/R_2.fits', 'group': 'n1', 'retainedWithout': .91},
      ];
      final job = await container
          .read(darkroomBuildJobsProvider.notifier)
          .startUnattended(
            'NGC891',
            outputRoot: Directory('${folder.path}/auto'),
          );
      expect(job.stage, DarkroomJobStage.awaitingReview);
      expect(native.built, isEmpty);
      expect(
        notifications.sent.single,
        contains('R_2.fits (91.0% without it)'),
      );
      expect(notifications.links.single, 'darkroom_framing:NGC891');
    },
  );

  test(
    'unattended fails at once, and says so, when the working folder will not fit',
    () async {
      final service = DarkroomBuildService(
        operation: native.call,
        library: CalibrationLibraryService(
          db: db,
          flatLibraryDao: FlatLibraryDao(db),
          tagsDao: CalibrationTagsDao(db),
        ),
        masters: IntegratedMastersDao(db),
        // Three 20000 x 20000 subs per filter: 4.8 GB of registered subs.
        readHeader: (_) async => {'NAXIS1': '20000', 'NAXIS2': '20000'},
        freeSpace: (_) async => 1 << 30,
      );
      final small = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          darkroomBuildServiceProvider.overrideWithValue(service),
          postSessionSeamProvider.overrideWithValue(seam),
          notificationServiceProvider.overrideWithValue(notifications),
        ],
      );
      addTearDown(small.dispose);
      final job = await small
          .read(darkroomBuildJobsProvider.notifier)
          .startUnattended(
            'NGC891',
            outputRoot: Directory('${folder.path}/auto'),
          );
      expect(job.stage, DarkroomJobStage.failed);
      expect(native.built, isEmpty);
      expect(job.error, contains('needs 5.0 GB'));
      expect(job.error, contains('1.0 GB is free'));
      expect(
        notifications.sent.single,
        allOf(startsWith('Master build failed: NGC891'), contains('is free')),
      );
    },
  );

  test('a finished unattended build is delivered and announced with one '
      'morning message', () async {
    final drop = await Directory('${folder.path}/nas').create();
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
    final job = await container
        .read(darkroomBuildJobsProvider.notifier)
        .startUnattended(
          'NGC891',
          outputRoot: Directory('${folder.path}/auto'),
          announce: false,
        );
    expect(job.stage, DarkroomJobStage.done);
    expect(
      notifications.sent,
      isEmpty,
      reason: 'the caller sends the morning message',
    );

    // The fake native writes no previews; give the masters theirs.
    for (final m in job.report!['delivery']['masters'] as List) {
      await File(m['previewPath'] as String).writeAsString('png');
    }
    final delivery = GuidedBuildDelivery(
      jobs: DarkroomJobsDao(db),
      delivery: DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (destination, jobId) =>
            WatchedFolderTransport(destination: destination, jobId: jobId),
      ),
      notifications: notifications,
    );
    final outcome = await delivery.deliver(job);

    expect(outcome.problems, isEmpty);
    // Two masters, two previews, the report and the frame audit.
    expect(outcome.delivery!.delivered, 6);
    expect(notifications.detailed, hasLength(1));
    final message = notifications.detailed.single;
    expect(message, startsWith('Masters ready: NGC891'));
    expect(message, contains('1 night, 2 subs used, 4 left out.'));
    expect(message, contains('L 1 sub, 2 min; R 1 sub, 2 min.'));
    expect(message, contains('of the field kept (95 x 75 px)'));
    expect(message, contains('No filter has flats (L, R)'));
    expect(message, contains('Delivered 6 files to 1 destination.'));
    expect(outcome.announced, isTrue);
    final row = await DarkroomJobsDao(db).getById(outcome.jobId);
    expect(row!.sessionId, isNull, reason: 'never re-run as a dawn draft pass');
    expect(row.state, DarkroomJobState.done);
  });

  test('a second build is refused while one runs', () async {
    final jobs = container.read(darkroomBuildJobsProvider.notifier);
    await jobs.checkFraming(target: 'NGC891', plan: await planFor());
    native.buildGate = Completer<void>();
    final running = jobs.accept(Directory('${folder.path}/out'));
    await native.buildStarted.future;
    await expectLater(jobs.startUnattended('NGC891'), throwsStateError);
    native.buildGate!.complete();
    await running;
  });

  group('across restarts', () {
    ProviderContainer restart() {
      final next = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          darkroomBuildServiceProvider.overrideWithValue(
            container.read(darkroomBuildServiceProvider),
          ),
          postSessionSeamProvider.overrideWithValue(seam),
          notificationServiceProvider.overrideWithValue(notifications),
        ],
      );
      addTearDown(next.dispose);
      return next;
    }

    test('a build held at the framing check comes back after a restart, '
        'and accepting it builds into its own folder', () async {
      native.retained = .55;
      final jobs = container.read(darkroomBuildJobsProvider.notifier);
      await jobs.startUnattended(
        'NGC891',
        outputRoot: Directory('${folder.path}/auto'),
      );
      await jobs.flush();

      final after = restart();
      final restored = after.read(darkroomBuildJobsProvider.notifier);
      await restored.restore();
      final job = after.read(darkroomBuildJobsProvider)!;
      expect(job.stage, DarkroomJobStage.awaitingReview);
      expect(job.plan!.lights, hasLength(6));
      expect(job.preview!.retainedArea, .55);

      await restored.setMinRetainedArea(.5);
      await restored.accept();
      final done = after.read(darkroomBuildJobsProvider)!;
      expect(done.stage, DarkroomJobStage.done);
      expect(done.directory, '${folder.path}/auto/NGC891');
      expect(native.built, ['L', 'R']);
    });

    test('a build running when the process ended comes back stopped and '
        'resumes from its folder', () async {
      final jobs = container.read(darkroomBuildJobsProvider.notifier);
      native.buildGate = Completer<void>();
      final running = jobs.startUnattended(
        'NGC891',
        outputRoot: Directory('${folder.path}/auto'),
      );
      await native.buildStarted.future;
      await jobs.flush();

      final after = restart();
      final restored = after.read(darkroomBuildJobsProvider.notifier);
      await restored.restore();
      final job = after.read(darkroomBuildJobsProvider)!;
      expect(job.stage, DarkroomJobStage.stopped);
      expect(job.message, contains('Resume keeps the finished filters'));
      expect(job.unattended, isTrue);
      native.buildGate!.complete();
      await running;
    });

    test('a second target does not push the first one\'s framing check '
        'out; it waits in the held list', () async {
      final other = await db.targetsDao.createTarget(
        TargetsCompanion.insert(name: 'M81', ra: 9.9, dec: 69),
      );
      final file = File('${folder.path}/M81_L.fits');
      await file.writeAsString('raw');
      await db.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          targetId: Value(other),
          filePath: file.path,
          fileName: 'M81_L.fits',
          exposureDuration: 120,
          filter: const Value('L'),
          sensorTemp: const Value(-10),
          capturedAt: DateTime(2026, 10, 22, 23),
        ),
      );
      native.retained = .55;
      final jobs = container.read(darkroomBuildJobsProvider.notifier);
      await jobs.startUnattended(
        'NGC891',
        outputRoot: Directory('${folder.path}/auto'),
      );
      native.retained = .9;
      await jobs.startUnattended(
        'M81',
        outputRoot: Directory('${folder.path}/auto'),
      );
      expect(container.read(darkroomBuildJobsProvider)!.target, 'M81');
      final held = container.read(darkroomHeldBuildsProvider);
      expect(held.single.target, 'NGC891');
      expect(jobs.heldFor('NGC891'), same(held.single));

      final reviewed = jobs.reviewHeld('NGC891')!;
      expect(container.read(darkroomBuildJobsProvider), same(reviewed));
      expect(container.read(darkroomHeldBuildsProvider), isEmpty);
      expect(
        container.read(darkroomRecentBuildsProvider).single.target,
        'M81',
        reason: 'the finished build is kept as a recent result',
      );
      await jobs.flush();

      final after = restart();
      await after.read(darkroomBuildJobsProvider.notifier).restore();
      expect(after.read(darkroomBuildJobsProvider)!.target, 'NGC891');
      expect(after.read(darkroomRecentBuildsProvider).single.target, 'M81');
    });
  });
}
